require "securerandom"

module Cybros
  module ProgrammableAgent
    class OperationSequence
      include Enumerable

      SEQUENCE_ID_PREFIX = "opseq_"

      attr_reader :origin, :sequence_id

      def initialize(origin:, sequence_id: nil)
        @origin = origin.to_s.strip
        raise ArgumentError, "origin is required" if @origin.blank?

        @sequence_id = sequence_id.to_s.strip.presence || "#{SEQUENCE_ID_PREFIX}#{SecureRandom.hex(12)}"
        @calls = []
      end

      def <<(call)
        raise TypeError, "call must be an OperationCall" unless call.is_a?(OperationCall)

        @calls << call
        self
      end

      def each(&block)
        @calls.each(&block)
      end

      def to_queue_payloads
        step_count = @calls.length

        @calls.each_with_index.map do |call, step_index|
          call.to_queue_payload(
            sequence_id: sequence_id,
            step_index: step_index,
            step_count: step_count,
            default_origin: origin,
          )
        end
      end
    end
  end
end
