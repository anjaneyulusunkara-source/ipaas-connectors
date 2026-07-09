require 'csv'
require 'stringio'

module IPaaS
  module Job
    # Parses in-memory CSV content into positional row arrays for use in a
    # connector +run+ block. Exposed to connector procs as the ProcSafe helper
    # +parse_csv+; the pure parsing logic lives in the class-level +parse+.
    #
    # The input is normalised to UTF-8 first, rows are returned as arrays (not
    # hashes) so a wide file does not repeat column keys on every row, blank
    # lines are skipped, the retained row count is capped at MAX_ROWS (a file
    # with more rows returns the first MAX_ROWS with truncated: true), and
    # rows wider than MAX_COLUMNS fail the parse; total memory stays
    # proportional to the already-bounded input.
    module Csv
      extend IPaaS::Connector::Common::ProcRules::ProcSafe

      proc_safe :parse_csv

      # The classic Excel row limit (2^16). A conservative starting cap; revisit
      # on customer feedback. truncated flags a hit.
      MAX_ROWS = 65_536
      # Bounds object amplification from a pathological oversized field.
      FIELD_SIZE_LIMIT = 8 * 1024 * 1024
      # Excel's column limit. Bounds object amplification from a row of many tiny
      # fields, which FIELD_SIZE_LIMIT cannot catch. A wider row almost always
      # means a wrong col_sep, so it fails the job instead of truncating.
      MAX_COLUMNS = 16_384

      # Byte-order marks, longest first so a 4-byte UTF-32 BOM is not shadowed by
      # a matching 2-byte UTF-16 prefix (UTF-32LE FF FE 00 00 vs UTF-16LE FF FE).
      BOMS = [
        ["\x00\x00\xFE\xFF".b, Encoding::UTF_32BE],
        ["\xFF\xFE\x00\x00".b, Encoding::UTF_32LE],
        ["\xEF\xBB\xBF".b,     Encoding::UTF_8],
        ["\xFF\xFE".b,         Encoding::UTF_16LE],
        ["\xFE\xFF".b,         Encoding::UTF_16BE],
      ].freeze

      # Raised when the input cannot be parsed as CSV, or when the parse options
      # (encoding, delimiter, quote char) are invalid.
      class MalformedInput < IPaaS::Error; end

      # ProcSafe helper for connector +run+ blocks. Fails the job with a clear
      # message when the content or options cannot be parsed.
      # @param content [String] raw CSV bytes or text in any encoding
      # @param headers [Boolean, nil] treat the first row as a header row (default true)
      # @param col_sep [String, nil] field delimiter (default +,+)
      # @param quote_char [String, nil] quote character (default +"+)
      # @param declared_encoding [String, nil] fallback used only when no BOM
      # @return [Hash] the five-key output contract
      def parse_csv(content, headers: nil, col_sep: nil, quote_char: nil, declared_encoding: nil)
        # A designer mapping can resolve an optional input to nil; drop those so
        # the parse defaults apply instead of nil acting as an explicit value.
        options = {
          headers: headers,
          col_sep: col_sep,
          quote_char: quote_char,
          declared_encoding: declared_encoding,
        }.compact
        IPaaS::Job::Csv.parse(content, **options)
      rescue IPaaS::Job::Csv::MalformedInput => e
        fail_job!("Could not parse the CSV: #{e.message}")
      end

      class << self
        # Pure parse: returns the output contract or raises MalformedInput.
        # @return [Hash] with keys :header, :rows, :truncated, :source_encoding,
        #   :lossy_encoding
        def parse(content, headers: true, col_sep: ',', quote_char: '"', declared_encoding: nil)
          raise MalformedInput, 'content must be a string' unless content.is_a?(String)

          utf8, source_encoding, lossy = normalize_encoding(content, declared_encoding)
          csv = build_csv(utf8, col_sep, quote_char)
          # Empty array (not nil) when there is no header row, so the array
          # output field maps cleanly instead of coercing nil into [nil].
          header = headers ? (csv.shift || []) : []
          check_columns!(header)
          rows, truncated = read_capped_rows(csv)
          build_output(header, rows, truncated, source_encoding, lossy)
        rescue CSV::MalformedCSVError, ArgumentError, Encoding::ConverterNotFoundError => e
          raise MalformedInput, e.message
        end

        private

        def build_csv(utf8, col_sep, quote_char)
          CSV.new(
            StringIO.new(utf8),
            col_sep: col_sep,
            quote_char: quote_char,
            headers: false,          # keep rows as plain arrays, not CSV::Row
            liberal_parsing: true,   # tolerate stray quotes rather than raising
            nil_value: '',           # empty fields are "" not nil (contract: all strings)
            max_field_size: FIELD_SIZE_LIMIT,
            skip_blanks: true        # else a blank trailing line trips a false-positive truncated
          )
        end

        # Stops shifting at the cap; eof? peeks (fully parses) the overflow row
        # but catches its parse error internally, so a malformed or oversized
        # overflow row cannot fail an already-complete result.
        # @return [Array(Array, Boolean)] rows, truncated?
        def read_capped_rows(csv)
          rows = []
          while rows.length < MAX_ROWS
            row = csv.shift
            return [rows, false] unless row

            check_columns!(row)
            rows << row
          end
          [rows, !csv.eof?]
        end

        def check_columns!(row)
          return if row.length <= MAX_COLUMNS

          raise MalformedInput,
                "Row has #{row.length} columns; the maximum is #{MAX_COLUMNS}. Check the col_sep option."
        end

        def build_output(header, rows, truncated, source_encoding, lossy)
          {
            header: header,
            rows: rows,
            truncated: truncated,
            source_encoding: source_encoding.to_s,
            lossy_encoding: lossy,
          }
        end

        # Normalises to UTF-8; a BOM wins over +declared_encoding+ and is stripped.
        # @return [Array(String, Encoding, Boolean)] utf8 text, source encoding, lossy?
        def normalize_encoding(content, declared_encoding)
          bytes = content.b
          # Resolve declared_encoding even when a BOM overrides it, so an invalid
          # value fails consistently instead of being ignored on BOM-prefixed input.
          declared = Encoding.find(declared_encoding || 'UTF-8')
          _, bom_encoding = BOMS.find { |bom, _| bytes.start_with?(bom) }
          source = bom_encoding || declared

          utf8, lossy = transcode_to_utf8(bytes.force_encoding(source))
          [utf8.delete_prefix("\uFEFF"), source, lossy]
        end

        # Strict conversion first, so lossy reflects every replacement: invalid
        # byte sequences and characters with no UTF-8 mapping alike.
        def transcode_to_utf8(text)
          if text.encoding == Encoding::UTF_8
            # Same-encoding encode does not validate, so check explicitly.
            return [text, false] if text.valid_encoding?
          else
            begin
              return [text.encode(Encoding::UTF_8), false]
            rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
              # fall through to the replacing conversion below
            end
          end
          [text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace), true]
        end
      end
    end
  end
end

IPaaS::Job::Context.extension(IPaaS::Job::Csv)
