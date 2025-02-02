# frozen_string_literal: true

require_relative "helpers/file_helper"

module Listen
  class QueueOptimizer
    class Config
      include FileHelper

      def initialize(adapter_class, silencer)
        @adapter_class = adapter_class
        @silencer = silencer
      end

      def exist?(path)
        Pathname(path).exist?
      end

      def silenced?(path, type)
        @silencer.silenced?(path, type)
      end

      def debug(*args, &block)
        Listen.logger.debug(*args, &block)
      end
    end

    def smoosh_changes(changes)
      # TODO: adapter could be nil at this point (shutdown)
      cookies = changes.group_by do |_, _, _, _, options|
        (options || {})[:cookie]
      end
      _squash_changes(_reinterpret_related_changes(cookies))
    end

    def initialize(config)
      @config = config
    end

    private

    attr_reader :config

    # groups changes into the expected structure expected by
    # clients
    def _squash_changes(changes)
      # We combine here for backward compatibility
      # Newer clients should receive dir and path separately
      changes = changes.map do |change, dir, path|
        dir = config.invalid_encoded_file?(path) ? dir.to_s : dir
        [change, dir + path]
      end

      actions = changes.group_by(&:last).map do |path, action_list|
        [_logical_action_for(path, action_list.map(&:first)), path.to_s]
      end

      config.debug("listen: raw changes: #{actions.inspect}")

      { modified: [], added: [], removed: [], invalid_file_path: [] }.tap do |squashed|
        actions.each do |type, path|
          squashed[type] << path unless type.nil?
        end
        config.debug("listen: final changes: #{squashed.inspect}")
      end
    end

    def _logical_action_for(path, actions)
      actions << :added if actions.delete(:moved_to)
      actions << :removed if actions.delete(:moved_from)

      modified = actions.find { |x| x == :modified }
      _calculate_add_remove_difference(actions, path, modified)
    end

    def _calculate_add_remove_difference(actions, path, default_if_exists)
      added = actions.count { |x| x == :added }
      removed = actions.count { |x| x == :removed }
      diff = added - removed

      # TODO: avoid checking if path exists and instead assume the events are
      # in order (if last is :removed, it doesn't exist, etc.)
      if config.invalid_encoded_file?(path)
        :invalid_file_path
      elsif config.exist?(path)
        if diff > 0
          :added
        elsif diff.zero? && added > 0
          :modified
        else
          default_if_exists
        end
      else
        diff < 0 ? :removed : nil
      end
    end

    # remove extraneous rb-inotify events, keeping them only if it's a possible
    # editor rename() call (e.g. Kate and Sublime)
    def _reinterpret_related_changes(cookies)
      table = { moved_to: :added, moved_from: :removed, invalid_file_path: :invalid_file_path}
      cookies.flat_map do |_, changes|
        if (editor_modified = editor_modified?(changes))
          [[:modified, *editor_modified]]
        else
          not_silenced = changes.reject do |type, _, _, path, _|
            unless config.invalid_encoded_file?(path)
              config.silenced?(Pathname(path), type)
            end
          end
          not_silenced.map do |_, change, dir, path, _|
            [table.fetch(change, change), dir, path]
          end
        end
      end
    end

    def editor_modified?(changes)
      return unless changes.size == 2

      from_type = from = nil
      to_type = to_dir = to = nil

      changes.each do |data|
        case data[1]
        when :moved_from
          from_type, _from_change, _, from, = data
        when :moved_to
          to_type, _to_change, to_dir, to, = data
        end
      end

      # Expect an ignored moved_from and non-ignored moved_to
      # to qualify as an "editor modify"
      if from && to && config.silenced?(Pathname(from), from_type) && !config.silenced?(Pathname(to), to_type)
        [to_dir, to]
      end
    end
  end
end
