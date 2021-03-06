require "lumberjack"

require "guard/ui"
require "guard/watcher"

module Guard
  # The runner is responsible for running all methods defined on each plugin.
  #
  class Runner
    # Runs a Guard-task on all registered plugins.
    #
    # @param [Symbol] task the task to run
    #
    # @param [Hash] scopes either the Guard plugin or the group to run the task
    # on
    #
    # @see self.run_supervised_task
    #
    def run(task, scope = {})
      Lumberjack.unit_of_work do
        _scoped_plugins(scope) do |guard|
          run_supervised_task(guard, task) if guard.respond_to?(task)
        end
      end
    end

    MODIFICATION_TASKS = [
      :run_on_modifications, :run_on_changes, :run_on_change
    ]

    ADDITION_TASKS     = [:run_on_additions, :run_on_changes, :run_on_change]
    REMOVAL_TASKS      = [:run_on_removals, :run_on_changes, :run_on_deletion]

    # Runs the appropriate tasks on all registered plugins
    # based on the passed changes.
    #
    # @param [Array<String>] modified the modified paths.
    # @param [Array<String>] added the added paths.
    # @param [Array<String>] removed the removed paths.
    #
    def run_on_changes(modified, added, removed)
      types = {
        MODIFICATION_TASKS => modified,
        ADDITION_TASKS => added,
        REMOVAL_TASKS => removed
      }

      ::Guard::UI.clearable

      _scoped_plugins do |guard|
        ::Guard::UI.clear

        types.each do |tasks, unmatched_paths|
          paths = ::Guard::Watcher.match_files(guard, unmatched_paths)
          next if paths.empty?

          next unless (task = tasks.detect { |meth| guard.respond_to?(meth) })
          run_supervised_task(guard, task, paths)
        end
      end
    end

    # Run a Guard plugin task, but remove the Guard plugin when his work leads
    # to a system failure.
    #
    # When the Group has `:halt_on_fail` disabled, we've to catch
    # `:task_has_failed` here in order to avoid an uncaught throw error.
    #
    # @param [Guard::Plugin] guard the Guard to execute
    # @param [Symbol] task the task to run
    # @param [Array] args the arguments for the task
    # @raise [:task_has_failed] when task has failed
    #
    def run_supervised_task(guard, task, *args)
      catch self.class.stopping_symbol_for(guard) do
        guard.hook("#{ task }_begin", *args)
        begin
          result = guard.send(task, *args)
        rescue Interrupt
          throw(:task_has_failed)
        end
        guard.hook("#{ task }_end", result)
        result
      end
    rescue ScriptError, StandardError, RuntimeError
      ::Guard::UI.error("#{ guard.class.name } failed to achieve its"\
                        " <#{ task }>, exception was:" \
                        "\n#{ $!.class }: #{ $!.message }" \
                        "\n#{ $!.backtrace.join("\n") }")
      ::Guard.plugins.delete guard
      ::Guard::UI.info("\n#{ guard.class.name } has just been fired")
      $!
    end

    # Returns the symbol that has to be caught when running a supervised task.
    #
    # @note If a Guard group is being run and it has the `:halt_on_fail`
    #   option set, this method returns :no_catch as it will be caught at the
    #   group level.
    # @see ._scoped_plugins
    #
    # @param [Guard::Plugin] guard the Guard plugin to execute
    # @return [Symbol] the symbol to catch
    #
    def self.stopping_symbol_for(guard)
      guard.group.options[:halt_on_fail] ? :no_catch : :task_has_failed
    end

    private

    # Loop through all groups and run the given task for each Guard plugin.
    #
    # If no scope is supplied, the global Guard scope is taken into account.
    # If both a plugin and a group scope is given, then only the plugin scope
    # is used.
    #
    # Stop the task run for the all Guard plugins within a group if one Guard
    # throws `:task_has_failed`.
    #
    # @param [Hash] scopes hash with plugins or a groups scope
    # @yield the task to run
    #
    def _scoped_plugins(scopes = {})
      if plugins = _current_plugins_scope(scopes)
        plugins.each do |guard|
          yield(guard)
        end
      else
        _current_groups_scope(scopes).each do |group|
          current_plugin = nil
          block_return = catch :task_has_failed do
            ::Guard.plugins(group: group.name).each do |guard|
              current_plugin = guard
              yield(guard)
            end
          end

          next unless block_return.nil?

          ::Guard::UI.info "#{ current_plugin.class.name } has failed,"\
            " other group's plugins execution has been halted."
        end
      end
    end

    # Returns the current plugins scope.
    # Local plugins scope wins over global plugins scope.
    # If no plugins scope is found, then NO plugins are returned.
    #
    # @param [Hash] scopes hash with a local plugins or a groups scope
    # @return [Array<Guard::Plugin>] the plugins to scope to
    #
    def _current_plugins_scope(scope)
      if plugins = _find_non_empty_plugins_scope(scope)
        Array(plugins).map do |plugin|
          plugin.is_a?(Symbol) ? ::Guard.plugin(plugin) : plugin
        end
      else
        nil
      end
    end

    # Returns the current groups scope.
    # Local groups scope wins over global groups scope.
    # If no groups scope is found, then ALL groups are returned.
    #
    # @param [Hash] scopes hash with a local plugins or a groups scope
    # @return [Array<Guard::Group>] the groups to scope to
    #
    def _current_groups_scope(scope)
      Array(_find_non_empty_groups_scope(scope)).map do |group|
        group.is_a?(Symbol) ? ::Guard.group(group) : group
      end
    end

    # Find the first non empty element in the given possibilities
    #
    def _find_non_empty_scope(type, local_scope, *additional_possibilities)
      found = [
        local_scope[:"#{type}s"],
        local_scope[type.to_sym],
        ::Guard.scope[:"#{type}s"],
        additional_possibilities.flatten
      ].compact.detect { |a| !Array(a).empty? }
      found ? [::Guard.group(:common)] + Array(found) : found
    end

    # Find the first non empty plugins scope
    #
    def _find_non_empty_plugins_scope(scope)
      _find_non_empty_scope(:plugin, scope)
    end

    # Find the first non empty groups scope
    #
    def _find_non_empty_groups_scope(scope)
      _find_non_empty_scope(:group, scope, ::Guard.groups)
    end
  end
end
