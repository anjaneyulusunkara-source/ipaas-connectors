require 'spec_helper'

describe 'Parse CSV', :action do
  let(:action_template_id) { '019f1ece-63b0-7d72-bdf3-3f1ee278967e' }

  describe 'input_schema' do
    context 'content field' do
      let(:field) { action.input_schema.field(:content) }

      it { expect(field.type).to eq(:string) }
      it { expect(field.required).to be_truthy }
    end

    context 'headers field' do
      let(:field) { action.input_schema.field(:headers) }

      it { expect(field.type).to eq(:boolean) }
      it { expect(field.default).to be(true) }
      it { expect(field.required).to be_falsey }
    end

    context 'col_sep field' do
      let(:field) { action.input_schema.field(:col_sep) }

      it { expect(field.type).to eq(:string) }
      it { expect(field.default).to eq(',') }
    end

    context 'quote_char field' do
      let(:field) { action.input_schema.field(:quote_char) }

      it { expect(field.type).to eq(:string) }
      it { expect(field.default).to eq('"') }
    end

    context 'declared_encoding field' do
      let(:field) { action.input_schema.field(:declared_encoding) }

      it { expect(field.type).to eq(:string) }
      it { expect(field.default).to eq('UTF-8') }
      it { expect(field.required).to be_falsey }
      it { expect(field.visibility).to eq('optional') }
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schema.first }

    it { expect(schema.field(:header).type).to eq(:string) }
    it { expect(schema.field(:header).array).to be_truthy }
    it { expect(schema.field(:rows).type).to eq(:any_item_type) }
    it { expect(schema.field(:rows).array).to be_truthy }
    it { expect(schema.field(:truncated).type).to eq(:boolean) }
    it { expect(schema.field(:source_encoding).type).to eq(:string) }
    it { expect(schema.field(:lossy_encoding).type).to eq(:boolean) }
  end

  describe 'run' do
    context 'happy path with a header' do
      subject(:output) { run_action({ content: "name,city\nAlice,NYC\n" }) }

      it 'returns the header' do
        expect(output[:header]).to eq(%w[name city])
      end

      it 'returns rows as arrays of string cells' do
        expect(output[:rows]).to eq([%w[Alice NYC]])
      end

      it 'is not truncated' do
        expect(output[:truncated]).to be(false)
      end

      it 'reports the source encoding as a string' do
        expect(output[:source_encoding]).to eq('UTF-8')
      end

      it 'is not flagged as lossy' do
        expect(output[:lossy_encoding]).to be(false)
      end
    end

    context 'a realistic multi-line document with quotes and embedded newlines' do
      subject(:output) { run_action({ content: document }) }

      let(:document) do
        <<~CSV
          id,name,notes,city
          1,"Smith, John","Line one
          Line two",NYC
          2,"O""Brien","He said ""hi""",LA
          3,,,
        CSV
      end

      it 'returns the header' do
        expect(output[:header]).to eq(%w[id name notes city])
      end

      it 'preserves a quoted comma and an embedded newline in one cell' do
        expect(output[:rows][0]).to eq(['1', 'Smith, John', "Line one\nLine two", 'NYC'])
      end

      it 'unescapes doubled quotes' do
        expect(output[:rows][1]).to eq(['2', 'O"Brien', 'He said "hi"', 'LA'])
      end

      it 'returns empty cells as empty strings' do
        expect(output[:rows][2]).to eq(['3', '', '', ''])
      end
    end

    context 'optional inputs resolved to nil by the mapping' do
      subject(:output) do
        run_action({ content: "name,city\nAlice,NYC\n",
                     headers: nil, col_sep: nil, quote_char: nil, declared_encoding: nil, })
      end

      it 'falls back to the defaults instead of treating nil as an explicit value' do
        expect(output[:header]).to eq(%w[name city])
        expect(output[:rows]).to eq([%w[Alice NYC]])
      end
    end

    context 'headers disabled' do
      subject(:output) { run_action({ content: "1,2\n3,4\n", headers: false }) }

      it 'returns an empty header' do
        expect(output[:header]).to eq([])
      end

      it 'treats the first row as data' do
        expect(output[:rows]).to eq([%w[1 2], %w[3 4]])
      end
    end

    context 'custom column separator' do
      subject(:output) { run_action({ content: "a;b\n1,2;3\n", col_sep: ';' }) }

      it 'splits on the custom separator and leaves commas inert' do
        expect(output[:rows]).to eq([['1,2', '3']])
      end
    end

    context 'input with invalid bytes for the declared encoding' do
      subject(:output) { run_action({ content: "a,b\n\x80x,2\n".b, declared_encoding: 'UTF-8' }) }

      it 'flags the transcode as lossy' do
        expect(output[:lossy_encoding]).to be(true)
      end
    end

    context 'a field larger than the field-size backstop' do
      before { stub_const('IPaaS::Job::Csv::FIELD_SIZE_LIMIT', 5) }

      it 'fails the job' do
        expect { run_action({ content: %("#{'a' * 50}"\n) }) }
          .to raise_error(IPaaS::Job::FailJob, /Field size exceeded/)
      end

      it 'parses a field exactly at the limit' do
        output = run_action({ content: %("#{'a' * 5}"\n), headers: false })
        expect(output[:rows]).to eq([['aaaaa']])
      end
    end

    context 'a row wider than the column cap' do
      before { stub_const('IPaaS::Job::Csv::MAX_COLUMNS', 3) }

      it 'fails the job' do
        expect { run_action({ content: "a,b,c,d\n1,2,3,4\n" }) }
          .to raise_error(IPaaS::Job::FailJob)
      end
    end

    context 'an invalid parse option' do
      it 'fails the job for an unknown declared_encoding' do
        expect { run_action({ content: "a,b\n1,2\n", declared_encoding: 'NOPE' }) }
          .to raise_error(IPaaS::Job::FailJob)
      end
    end
  end
end
