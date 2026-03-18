module LaneProcesses
  class LogReader
    CHUNK_SIZE = 4096
    DEFAULT_TAIL_LINES = 200
    MAX_TAIL_LINES = 500

    def self.call(lane_process:, tail_lines: DEFAULT_TAIL_LINES)
      new(lane_process: lane_process, tail_lines: tail_lines).call
    end

    def initialize(lane_process:, tail_lines:)
      @lane_process = lane_process
      @tail_lines = tail_lines
    end

    def call
      return [] if lane_process.log_path.blank?
      return [] unless File.file?(lane_process.log_path)

      tail_lines_from_file(lane_process.log_path, normalized_tail_lines)
    end

    private

      attr_reader :lane_process, :tail_lines

      def normalized_tail_lines
        raw = Integer(tail_lines, exception: false)
        raw = DEFAULT_TAIL_LINES if raw.nil?
        raw = 1 if raw < 1
        [raw, MAX_TAIL_LINES].min
      end

      def tail_lines_from_file(path, line_count)
        buffer = +""

        File.open(path, "rb") do |file|
          position = file.size

          while position.positive? && buffer.count("\n") <= line_count
            read_size = [CHUNK_SIZE, position].min
            position -= read_size
            file.seek(position)
            buffer.prepend(file.read(read_size))
          end
        end

        buffer.lines(chomp: true).last(line_count) || []
      end
  end
end
