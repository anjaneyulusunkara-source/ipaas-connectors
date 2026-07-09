require 'spec_helper'

describe IPaaS::Job::Csv do
  describe '.parse' do
    context 'basic parse with a header' do
      subject(:result) { described_class.parse("name,city\nAlice,NYC\nBob,LA\n") }

      it 'returns the first row as the header array' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'returns data rows as positional string arrays' do
        expect(result[:rows]).to eq([%w[Alice NYC], %w[Bob LA]])
      end

      it 'is not truncated' do
        expect(result[:truncated]).to be(false)
      end
    end

    context 'quoted field with an embedded newline and comma' do
      subject(:result) { described_class.parse("a,b\n\"multi\nline, with comma\",2\n") }

      it 'keeps the quoted content as a single field' do
        expect(result[:rows]).to eq([["multi\nline, with comma", '2']])
      end

      it 'treats the two physical lines as one logical row' do
        expect(result[:rows][0][0]).to include("\n")
      end
    end

    context 'doubled quotes inside a quoted field' do
      subject(:result) { described_class.parse(%(a,b\n"she said ""hi""",2\n)) }

      it 'unescapes the doubled quotes' do
        expect(result[:rows]).to eq([['she said "hi"', '2']])
      end
    end

    context 'a header row with quoted embedded newlines and commas' do
      subject(:result) { described_class.parse(document) }

      let(:document) do
        <<~CSV
          "first
          name","home, town"
          Alice,NYC
        CSV
      end

      it 'keeps the embedded newline and comma inside the header cells' do
        expect(result[:header]).to eq(["first\nname", 'home, town'])
      end

      it 'reads the data row that follows the multi-line header' do
        expect(result[:rows]).to eq([%w[Alice NYC]])
      end
    end

    context 'ragged rows' do
      subject(:result) { described_class.parse("a,b,c\n1,2\n4,5,6,7\n") }

      it 'keeps a short row short' do
        expect(result[:rows][0]).to eq(%w[1 2])
      end

      it 'keeps a long row long' do
        expect(result[:rows][1]).to eq(%w[4 5 6 7])
      end
    end

    context 'empty fields' do
      subject(:result) { described_class.parse("a,\n1,\n,3\n") }

      it 'reports an empty header cell as an empty string, not nil' do
        expect(result[:header]).to eq(['a', ''])
      end

      it 'reports empty data cells as empty strings, not nil' do
        expect(result[:rows]).to eq([['1', ''], ['', '3']])
      end
    end

    context 'custom column separator' do
      subject(:result) { described_class.parse("a;b\n1,2;3\n", col_sep: ';') }

      it 'splits on the custom separator and leaves commas inert' do
        expect(result[:rows]).to eq([['1,2', '3']])
      end
    end

    context 'UTF-8 input with a byte-order mark' do
      subject(:result) { described_class.parse("\xEF\xBB\xBFname,city\nA,B\n".b) }

      it 'strips the byte-order mark from the first header cell' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'reports the source encoding as UTF-8' do
        expect(result[:source_encoding]).to eq('UTF-8')
      end

      it 'is not flagged as lossy' do
        expect(result[:lossy_encoding]).to be(false)
      end
    end

    context 'UTF-16LE input with a byte-order mark' do
      subject(:result) do
        utf16 = "\xFF\xFE".b + "name,city\nJoão,Ω\n".encode('UTF-16LE').b
        described_class.parse(utf16)
      end

      it 'decodes the header' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'decodes multibyte values' do
        expect(result[:rows]).to eq([%w[João Ω]])
      end

      it 'reports the source encoding as UTF-16LE' do
        expect(result[:source_encoding]).to eq('UTF-16LE')
      end

      it 'is not flagged as lossy' do
        expect(result[:lossy_encoding]).to be(false)
      end
    end

    context 'UTF-16BE input with a byte-order mark' do
      subject(:result) do
        utf16 = "\xFE\xFF".b + "name,city\nJoão,Ω\n".encode('UTF-16BE').b
        described_class.parse(utf16)
      end

      it 'decodes the header' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'decodes multibyte values' do
        expect(result[:rows]).to eq([%w[João Ω]])
      end

      it 'reports the source encoding as UTF-16BE' do
        expect(result[:source_encoding]).to eq('UTF-16BE')
      end

      it 'is not flagged as lossy' do
        expect(result[:lossy_encoding]).to be(false)
      end
    end

    context 'UTF-32LE input with a byte-order mark' do
      subject(:result) do
        utf32 = "\xFF\xFE\x00\x00".b + "name,city\nA,B\n".encode('UTF-32LE').b
        described_class.parse(utf32)
      end

      it 'decodes the header (not mis-detected as UTF-16LE)' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'reports the source encoding as UTF-32LE' do
        expect(result[:source_encoding]).to eq('UTF-32LE')
      end
    end

    context 'UTF-32BE input with a byte-order mark' do
      subject(:result) do
        utf32 = "\x00\x00\xFE\xFF".b + "name,city\nA,B\n".encode('UTF-32BE').b
        described_class.parse(utf32)
      end

      it 'decodes the header' do
        expect(result[:header]).to eq(%w[name city])
      end

      it 'reports the source encoding as UTF-32BE' do
        expect(result[:source_encoding]).to eq('UTF-32BE')
      end
    end

    context 'byte-order mark conflicting with declared_encoding' do
      subject(:result) do
        utf16 = "\xFF\xFE".b + "name,city\nJoão,Ω\n".encode('UTF-16LE').b
        described_class.parse(utf16, declared_encoding: 'UTF-8')
      end

      it 'lets the byte-order mark win over the declared encoding' do
        expect(result[:source_encoding]).to eq('UTF-16LE')
      end

      it 'decodes the content as UTF-16LE' do
        expect(result[:rows]).to eq([%w[João Ω]])
      end
    end

    context 'invalid bytes for the declared encoding' do
      subject(:result) { described_class.parse("a,b\n\x80x,2\n".b, declared_encoding: 'UTF-8') }

      it 'flags the transcode as lossy' do
        expect(result[:lossy_encoding]).to be(true)
      end

      it 'preserves the valid content around the replaced byte' do
        expect(result[:rows][0].last).to eq('2')
        expect(result[:rows][0].first).to end_with('x')
      end
    end

    context 'bytes without a UTF-8 mapping under a declared binary encoding' do
      subject(:result) { described_class.parse("a,b\ncaf\xE9,2\n".b, declared_encoding: 'ASCII-8BIT') }

      # Every byte is valid in ASCII-8BIT, so lossiness here comes from the
      # replacement during transcoding, not from invalid input bytes.
      it 'flags the transcode as lossy' do
        expect(result[:lossy_encoding]).to be(true)
      end

      it 'replaces only the unmappable byte' do
        expect(result[:rows]).to eq([['caf�', '2']])
      end
    end

    context 'valid UTF-8 input without a byte-order mark' do
      subject(:result) { described_class.parse("a,b\n1,2\n") }

      it 'reports the source encoding as UTF-8' do
        expect(result[:source_encoding]).to eq('UTF-8')
      end

      it 'is not flagged as lossy' do
        expect(result[:lossy_encoding]).to be(false)
      end
    end

    # Genuine multibyte UTF-8 without a BOM, so the valid_encoding? fast path
    # is exercised with content the ASCII-only fixtures cannot reach.
    context 'multibyte UTF-8 input without a byte-order mark' do
      subject(:result) { described_class.parse("prénom,ville\nÉlodie,Montréal\n") }

      it 'round-trips the multibyte header and values' do
        expect(result[:header]).to eq(%w[prénom ville])
        expect(result[:rows]).to eq([%w[Élodie Montréal]])
      end

      it 'is not flagged as lossy' do
        expect(result[:lossy_encoding]).to be(false)
      end
    end

    context 'empty input' do
      subject(:result) { described_class.parse('') }

      it 'returns an empty header' do
        expect(result[:header]).to eq([])
      end

      it 'returns no rows' do
        expect(result[:rows]).to eq([])
      end

      it 'is not truncated' do
        expect(result[:truncated]).to be(false)
      end
    end

    context 'headers disabled' do
      subject(:result) { described_class.parse("1,2\n3,4\n", headers: false) }

      it 'returns an empty header' do
        expect(result[:header]).to eq([])
      end

      it 'treats the first physical row as data' do
        expect(result[:rows]).to eq([%w[1 2], %w[3 4]])
      end
    end

    context 'row count exceeds the safety cap' do
      subject(:result) { described_class.parse("h\nrow1\nrow2\nrow3\nrow4\nrow5\n") }

      before { stub_const('IPaaS::Job::Csv::MAX_ROWS', 3) }

      it 'keeps exactly the cap of rows' do
        expect(result[:rows]).to eq([['row1'], ['row2'], ['row3']])
      end

      it 'flags the result as truncated' do
        expect(result[:truncated]).to be(true)
      end
    end

    context 'row count exactly equals the safety cap' do
      subject(:result) { described_class.parse("h\na\nb\nc\n") }

      before { stub_const('IPaaS::Job::Csv::MAX_ROWS', 3) }

      it 'keeps all rows' do
        expect(result[:rows]).to eq([['a'], ['b'], ['c']])
      end

      it 'is not truncated' do
        expect(result[:truncated]).to be(false)
      end
    end

    context 'a trailing blank line after exactly the safety cap of rows' do
      subject(:result) { described_class.parse("h\na\nb\nc\n\n") }

      before { stub_const('IPaaS::Job::Csv::MAX_ROWS', 3) }

      it 'keeps all rows' do
        expect(result[:rows]).to eq([['a'], ['b'], ['c']])
      end

      # The blank line is skipped, not peeked as an overflow row.
      it 'is not truncated' do
        expect(result[:truncated]).to be(false)
      end
    end

    context 'blank lines within the data' do
      subject(:result) { described_class.parse("a,b\n1,2\n\n3,4\n") }

      it 'skips them instead of returning empty rows' do
        expect(result[:rows]).to eq([%w[1 2], %w[3 4]])
      end
    end

    context 'a malformed row beyond the safety cap' do
      before { stub_const('IPaaS::Job::Csv::MAX_ROWS', 3) }

      # The overflow row is never parsed as a kept row, so its defect must not
      # fail the already-complete truncated result.
      it 'returns the capped rows and flags truncation instead of raising' do
        result = described_class.parse(%(h\na\nb\nc\n"unclosed\n))
        expect(result[:rows]).to eq([['a'], ['b'], ['c']])
        expect(result[:truncated]).to be(true)
      end

      it 'still raises MalformedInput when the malformed row is within the cap' do
        expect { described_class.parse(%(h\na\n"unclosed\n)) }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end
    end

    context 'a field larger than the field-size backstop' do
      before { stub_const('IPaaS::Job::Csv::FIELD_SIZE_LIMIT', 5) }

      it 'raises MalformedInput' do
        oversized = %("#{'a' * 50}"\n)
        expect { described_class.parse(oversized) }
          .to raise_error(IPaaS::Job::Csv::MalformedInput, /Field size exceeded/)
      end

      it 'parses a field exactly at the limit' do
        expect(described_class.parse(%("#{'a' * 5}"\n), headers: false)[:rows]).to eq([['aaaaa']])
      end
    end

    context 'rows wider than the column cap' do
      before { stub_const('IPaaS::Job::Csv::MAX_COLUMNS', 3) }

      it 'raises MalformedInput for a too-wide data row' do
        expect { described_class.parse("a,b\n1,2,3,4\n") }
          .to raise_error(IPaaS::Job::Csv::MalformedInput, /4 columns; the maximum is 3/)
      end

      it 'raises MalformedInput for a too-wide header row' do
        expect { described_class.parse("a,b,c,d\n1,2\n") }
          .to raise_error(IPaaS::Job::Csv::MalformedInput, /4 columns; the maximum is 3/)
      end

      it 'parses a row exactly at the cap' do
        expect(described_class.parse("a,b,c\n1,2,3\n")[:rows]).to eq([%w[1 2 3]])
      end

      # The row beyond MAX_ROWS is peeked for truncation detection but never
      # kept, so it must not be column-checked either.
      it 'does not column-check a too-wide row that is discarded past the row cap' do
        stub_const('IPaaS::Job::Csv::MAX_ROWS', 2)
        result = described_class.parse("h\na\nb\n1,2,3,4,5\n")
        expect(result[:rows]).to eq([['a'], ['b']])
        expect(result[:truncated]).to be(true)
      end
    end

    context 'invalid parse options' do
      it 'raises MalformedInput for an unknown declared_encoding' do
        expect { described_class.parse("a,b\n1,2\n", declared_encoding: 'NOPE') }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'raises MalformedInput for a declared_encoding without a converter to UTF-8' do
        expect { described_class.parse("a,b\n1,2\n", declared_encoding: 'UTF-7') }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'raises MalformedInput for a blank column separator' do
        expect { described_class.parse("a,b\n1,2\n", col_sep: '') }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'raises MalformedInput for a multi-character quote character' do
        expect { described_class.parse("a,b\n1,2\n", quote_char: '""') }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'raises MalformedInput for nil content' do
        expect { described_class.parse(nil) }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'raises MalformedInput for non-string content' do
        expect { described_class.parse(42) }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end

      it 'validates declared_encoding even when a byte-order mark is present' do
        utf8_bom = "\xEF\xBB\xBFa,b\n1,2\n".b
        expect { described_class.parse(utf8_bom, declared_encoding: 'NOPE') }
          .to raise_error(IPaaS::Job::Csv::MalformedInput)
      end
    end

    context 'a realistic multi-line document with quotes, embedded newlines and empty cells' do
      subject(:result) { described_class.parse(document) }

      # A quoted field spanning two physical lines, a quoted comma, doubled
      # quotes, and a row of empty cells — all in one document.
      let(:document) do
        <<~CSV
          id,name,notes,city
          1,"Smith, John","Line one
          Line two",NYC
          2,"O""Brien","He said ""hi""",LA
          3,,,
        CSV
      end

      it 'reads the header' do
        expect(result[:header]).to eq(%w[id name notes city])
      end

      it 'keeps a quoted comma and a quoted embedded newline within one cell of one row' do
        expect(result[:rows][0]).to eq(['1', 'Smith, John', "Line one\nLine two", 'NYC'])
      end

      it 'unescapes doubled quotes in both fields of the next row' do
        expect(result[:rows][1]).to eq(['2', 'O"Brien', 'He said "hi"', 'LA'])
      end

      it 'reads a row of empty cells as empty strings' do
        expect(result[:rows][2]).to eq(['3', '', '', ''])
      end

      it 'reads exactly three data rows' do
        expect(result[:rows].length).to eq(3)
      end

      it 'is not truncated' do
        expect(result[:truncated]).to be(false)
      end
    end

    context 'output shape' do
      subject(:result) { described_class.parse("a,b\n1,2\n") }

      it 'returns exactly the five contract keys' do
        expect(result.keys).to eq([:header, :rows, :truncated, :source_encoding, :lossy_encoding])
      end

      it 'reports the source encoding as a string' do
        expect(result[:source_encoding]).to eq('UTF-8')
      end
    end
  end
end
