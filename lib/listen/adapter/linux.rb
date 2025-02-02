# frozen_string_literal: true

module Listen
  module Adapter
    # @see https://github.com/nex3/rb-inotify
    class Linux < Base
      OS_REGEXP = /linux/i.freeze

      DEFAULTS = {
        events: [
          :recursive,
          :attrib,
          :create,
          :modify,
          :delete,
          :move,
          :close_write
        ],
        wait_for_delay: 0.1
      }.freeze

      private

      README_URL = 'https://github.com/guard/listen'\
        '/blob/master/README.md#increasing-the-amount-of-inotify-watchers'

      def _configure(directory, &callback)
        require 'rb-inotify'
        @worker ||= ::INotify::Notifier.new
        @worker.watch(directory.to_s, *options.events, &callback)
      rescue Errno::ENOSPC
        raise ::Listen::Error::INotifyMaxWatchesExceeded, <<~EOS
          Unable to monitor directories for changes because iNotify max watches exceeded. See #{README_URL} .
        EOS
      end

      def _run
        @worker.run
      end

      # rubocop:disable Metrics/MethodLength
      def _process_event(dir, event)
        # NOTE: avoid using event.absolute_name since new API
        # will need to have a custom recursion implemented
        # to properly match events to configured directories
        path = "#{event.watcher.path}/#{event.name}"
        if invalid_encoded_file?(path)
          _queue_change(:file, dir, path, invalid_file_path: true)
          return
        end

        path = Pathname.new(event.watcher.path) + event.name
        rel_path = path.relative_path_from(dir).to_s

        Listen.logger.debug { "inotify: #{rel_path} (#{event.flags.inspect})" }

        if /1|true/ =~ ENV['LISTEN_GEM_SIMULATE_FSEVENT']
          if (event.flags & [:moved_to, :moved_from]) || _dir_event?(event)
            rel_path = path.dirname.relative_path_from(dir).to_s
          end
          _queue_change(:dir, dir, rel_path, {})
          return
        end

        return if _skip_event?(event)

        cookie_params = event.cookie.zero? ? {} : { cookie: event.cookie }

        # Note: don't pass options to force rescanning the directory, so we can
        # detect moving/deleting a whole tree
        if _dir_event?(event)
          _queue_change(:dir, dir, rel_path, cookie_params)
          return
        end

        params = cookie_params.merge(change: _change(event.flags))

        _queue_change(:file, dir, rel_path, params)
      end
      # rubocop:enable Metrics/MethodLength

      def _skip_event?(event)
        # Event on root directory
        return true if event.name == ''
        # INotify reports changes to files inside directories as events
        # on the directories themselves too.
        #
        # @see http://linux.die.net/man/7/inotify
        _dir_event?(event) && (event.flags & [:close, :modify]).any?
      end

      def _change(event_flags)
        { modified:   [:attrib, :close_write],
          moved_to:   [:moved_to],
          moved_from: [:moved_from],
          added:      [:create],
          removed:    [:delete] }.each do |change, flags|
          return change unless (flags & event_flags).empty?
        end
        nil
      end

      def _dir_event?(event)
        event.flags.include?(:isdir)
      end

      def _stop
        @worker&.close

        super
      end
    end
  end
end
