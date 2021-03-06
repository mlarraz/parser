module Parser
  module Source

    ##
    # {Rewriter} performs the heavy lifting in the source rewriting process.
    # It schedules code updates to be performed in the correct order and
    # verifies that no two updates _clobber_ each other, that is, attempt to
    # modify the same part of code.
    #
    # If it is detected that one update clobbers another one, an `:error` and
    # a `:note` diagnostics describing both updates are generated and passed to
    # the diagnostic engine. After that, an exception is raised.
    #
    # The default diagnostic engine consumer simply prints the diagnostics to `stderr`.
    #
    # @!attribute [r] source_buffer
    #  @return [Source::Buffer]
    #
    # @!attribute [r] diagnostics
    #  @return [Diagnostic::Engine]
    #
    # @api public
    #
    class Rewriter
      attr_reader :source_buffer
      attr_reader :diagnostics

      ##
      # @param [Source::Buffer] source_buffer
      #
      def initialize(source_buffer)
        @diagnostics = Diagnostic::Engine.new
        @diagnostics.consumer = lambda do |diag|
          $stderr.puts diag.render
        end

        @source_buffer = source_buffer
        @queue         = []
        @clobber       = 0
      end

      ##
      # Removes the source range.
      #
      # @param [Range] range
      # @return [Rewriter] self
      # @raise [ClobberingError] when clobbering is detected
      #
      def remove(range)
        append Rewriter::Action.new(range, '')
      end

      ##
      # Inserts new code before the given source range.
      #
      # @param [Range] range
      # @param [String] content
      # @return [Rewriter] self
      # @raise [ClobberingError] when clobbering is detected
      #
      def insert_before(range, content)
        append Rewriter::Action.new(range.begin, content)
      end

      ##
      # Inserts new code after the given source range.
      #
      # @param [Range] range
      # @param [String] content
      # @return [Rewriter] self
      # @raise [ClobberingError] when clobbering is detected
      #
      def insert_after(range, content)
        append Rewriter::Action.new(range.end, content)
      end

      ##
      # Replaces the code of the source range `range` with `content`.
      #
      # @param [Range] range
      # @param [String] content
      # @return [Rewriter] self
      # @raise [ClobberingError] when clobbering is detected
      #
      def replace(range, content)
        append Rewriter::Action.new(range, content)
      end

      ##
      # Applies all scheduled changes to the `source_buffer` and returns
      # modified source as a new string.
      #
      # @return [String]
      #
      def process
        if in_transaction?
          raise "Do not call #{self.class}##{__method__} inside a transaction"
        end

        adjustment = 0
        source     = @source_buffer.source.dup

        sorted_queue = @queue.sort_by.with_index do |action, index|
          [action.range.begin_pos, index]
        end

        sorted_queue.each do |action|
          begin_pos = action.range.begin_pos + adjustment
          end_pos   = begin_pos + action.range.length

          source[begin_pos...end_pos] = action.replacement

          adjustment += (action.replacement.length - action.range.length)
        end

        source
      end

      ##
      # Provides a protected block where a sequence of multiple rewrite actions
      # are handled atomic. If any of the action failed by clobbering,
      # all the actions are rolled back.
      #
      # @example
      #  begin
      #    rewriter.transaction do
      #      rewriter.insert_before(range_of_something, '(')
      #      rewriter.insert_after(range_of_something, ')')
      #    end
      #  rescue Parser::ClobberingError
      #  end
      #
      # @raise [RuntimeError] when no block is passed
      # @raise [RuntimeError] when already in a transaction
      #
      def transaction
        unless block_given?
          raise "#{self.class}##{__method__} requires block"
        end

        if in_transaction?
          raise 'Nested transaction is not supported'
        end

        @pending_queue = @queue.dup
        @pending_clobber = @clobber

        yield

        @queue = @pending_queue
        @clobber = @pending_clobber

        self
      ensure
        @pending_queue = nil
        @pending_clobber = nil
      end

      private

      def append(action)
        if (clobber_actions = clobbered?(action.range))
          handle_clobber(action, clobber_actions)
        else
          clobber(action.range)
          active_queue << action
        end

        self
      end

      def clobber(range)
        self.active_clobber = active_clobber | (2 ** range.size - 1) << range.begin_pos
      end

      def clobbered?(range)
        if active_clobber & ((2 ** range.size - 1) << range.begin_pos) != 0
          active_queue.select do |action|
            action.range.end_pos > range.begin_pos &&
              range.end_pos > action.range.begin_pos
          end
        end
      end

      def handle_clobber(action, existing)
        if can_merge?(action, existing)
          merge_actions!(action, existing)
        else
          # cannot replace 3 characters with "foobar"
          diagnostic = Diagnostic.new(:error,
                                      :invalid_action,
                                      { :action => action },
                                      action.range)
          @diagnostics.process(diagnostic)

          # clobbered by: remove 3 characters
          diagnostic = Diagnostic.new(:note,
                                      :clobbered,
                                      { :action => existing[0] },
                                      existing[0].range)
          @diagnostics.process(diagnostic)

          raise ClobberingError, "Parser::Source::Rewriter detected clobbering"
        end
      end

      def can_merge?(action, existing)
        existing.all? do |other|
          overlap       = action.range.intersect(other.range)
          action_offset = overlap.begin_pos - action.range.begin_pos
          other_offset  = overlap.begin_pos - other.range.begin_pos

          replacement1 = action.replacement[action_offset, overlap.size] || ''
          replacement2 = other.replacement[other_offset, overlap.size] || ''
          replacement1 == replacement2
        end
      end

      def merge_actions!(action, existing)
        actions      = existing.push(action).sort_by { |a| a.range.begin_pos }
        merged_begin = actions.map { |act| act.range.begin_pos }.min
        merged_end   = actions.map { |act| act.range.end_pos }.max
        range        = Source::Range.new(@source_buffer,
                                         merged_begin,
                                         merged_end)
        clobber(range)

        replacement = merge_replacements(actions)
        replace_actions(actions, Rewriter::Action.new(range, replacement))
      end

      def replace_actions(old, updated)
        old.each { |act| active_queue.delete(act) }
        active_queue << updated
      end

      def merge_replacements(actions)
        # `actions` must be sorted by beginning position
        begin_pos = actions.first.range.begin_pos
        result    = ''

        actions.each do |act|
          offset = result.size - act.range.begin_pos + begin_pos
          next if offset < 0 || offset >= act.replacement.size
          result << act.replacement[offset..-1]
        end

        result
      end

      def in_transaction?
        !@pending_queue.nil?
      end

      def active_queue
        @pending_queue || @queue
      end

      def active_clobber
        @pending_clobber || @clobber
      end

      def active_clobber=(value)
        if @pending_clobber
          @pending_clobber = value
        else
          @clobber = value
        end
      end
    end

  end
end
