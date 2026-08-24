require 'spec_helper'

describe 'Slack Upload File Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-74c3-befd-cfb7a1040fcf' }

  describe 'input_schema' do
    it 'defines required fields' do
      action.input_schema.field(:channel_id).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end

      action.input_schema.field(:content).tap do |field|
        expect(field.type).to eq(:binary)
        expect(field.required).to be_truthy
      end

      action.input_schema.field(:filename).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end

    it 'defines optional fields' do
      action.input_schema.field(:title).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_falsey
        expect(field.visibility).to eq('optional')
      end

      action.input_schema.field(:initial_comment).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_falsey
        expect(field.visibility).to eq('optional')
      end
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schemas.first }

    it 'defines output fields' do
      expect(schema.field(:ok).type).to eq(:boolean)
      expect(schema.field(:ok).required).to be_truthy

      files_field = schema.field(:files)
      expect(files_field.type).to eq(:nested)
      expect(files_field.array).to be_truthy
      expect(files_field.field(:id).type).to eq(:string)
      expect(files_field.field(:title).type).to eq(:string)
    end
  end

  describe 'run' do
    let(:get_upload_url) { "#{slack_api}/files.getUploadURLExternal" }
    let(:complete_url) { "#{slack_api}/files.completeUploadExternal" }
    let(:upload_url) { 'https://files.slack.com/upload/v1/abc123' }

    let(:base_input) do
      { channel_id: 'C123', content: 'hello', filename: 'test.txt' }
    end

    describe 'successful upload' do
      before do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F123',
          }.to_json)

        stub_request(:post, upload_url)
          .with(body: 'hello', headers: { 'Content-Type' => 'application/octet-stream' })
          .to_return(status: 200, body: 'OK')

        stub_request(:post, complete_url)
          .to_return(status: 200, body: {
            ok: true, files: [{ id: 'F123', title: 'test.txt' }],
          }.to_json)
      end

      it 'uploads file and returns file info' do
        output = run_action(base_input)
        expect(output[:ok]).to eq(true)
        expect(output[:files].first[:id]).to eq('F123')
        expect(output[:files].first[:title]).to eq('test.txt')
      end

      it 'sends correct authorization header to Slack API but not to upload URL' do
        get_stub = stub_request(:post, get_upload_url)
                   .with(
                     body: { filename: 'test.txt', length: '5' },
                     headers: { 'Authorization' => 'Bearer xoxb-test-token',
                                'Content-Type' => 'application/x-www-form-urlencoded', }
                   )
                   .to_return(status: 200, body: {
                     ok: true, upload_url: upload_url, file_id: 'F123',
                   }.to_json)

        post_stub = stub_request(:post, upload_url)
                    .with { |req| req.headers['Authorization'].nil? }
                    .to_return(status: 200, body: 'OK')

        run_action(base_input)
        expect(get_stub).to have_been_requested.once
        expect(post_stub).to have_been_requested.once
      end
    end

    describe 'with binary content' do
      let(:binary_content) { "\x00\x01\xff\xfe\x80".b }

      it 'sends raw bytes and reports byte length accurately' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'logo.png', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F999',
          }.to_json)

        upload_stub = stub_request(:post, upload_url)
                      .with(body: binary_content,
                            headers: { 'Content-Type' => 'application/octet-stream' })
                      .to_return(status: 200, body: 'OK')

        stub_request(:post, complete_url)
          .to_return(status: 200, body: {
            ok: true, files: [{ id: 'F999', title: 'logo.png' }],
          }.to_json)

        run_action({ channel_id: 'C123', content: binary_content, filename: 'logo.png' })
        expect(upload_stub).to have_been_requested.once
      end
    end

    describe 'with optional parameters' do
      before do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'report.pdf', length: '11' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F456',
          }.to_json)

        stub_request(:post, upload_url)
          .to_return(status: 200, body: 'OK')
      end

      it 'includes title and initial_comment in complete request' do
        complete_stub = stub_request(:post, complete_url)
                        .with do |req|
                          body = JSON.parse(req.body)
                          body['files'] == [{ 'id' => 'F456', 'title' => 'My Report' }] &&
                            body['channel_id'] == 'C123' &&
                            body['initial_comment'] == 'Here is the report'
                        end
                        .to_return(status: 200, body: {
                          ok: true, files: [{ id: 'F456', title: 'My Report' }],
                        }.to_json)

        output = run_action({
          channel_id: 'C123',
          content: 'PDF content',
          filename: 'report.pdf',
          title: 'My Report',
          initial_comment: 'Here is the report',
        })

        expect(output[:ok]).to eq(true)
        expect(output[:files].first[:title]).to eq('My Report')
        expect(complete_stub).to have_been_requested.once
      end
    end

    describe 'error handling' do
      it 'fails when getUploadURLExternal returns API error' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: false, error: 'not_authed',
          }.to_json)

        expect { run_action(base_input) }.to raise_error(
          IPaaS::Job::FailJob, 'Slack API error: not_authed'
        )
      end

      it 'fails when getUploadURLExternal omits file_id, without POSTing the file' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url,
          }.to_json)

        expect { run_action(base_input) }.to raise_error(
          IPaaS::Job::FailJob, 'files.getUploadURLExternal did not return a file_id'
        )
        expect(WebMock).not_to have_requested(:post, upload_url)
      end

      it 'fails when file upload POST returns non-200' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F123',
          }.to_json)

        stub_request(:post, upload_url)
          .to_return(status: 403, body: 'Forbidden')

        expect { run_action(base_input) }.to raise_error(
          IPaaS::Job::FailJob, "File upload failed: 403 'Forbidden'"
        )
      end

      it 'fails when completeUploadExternal returns API error' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F123',
          }.to_json)

        stub_request(:post, upload_url)
          .to_return(status: 200, body: 'OK')

        stub_request(:post, complete_url)
          .to_return(status: 200, body: {
            ok: false, error: 'invalid_arguments',
          }.to_json)

        expect { run_action(base_input) }.to raise_error(
          IPaaS::Job::FailJob, 'Slack API error: invalid_arguments'
        )
      end

      it 'handles 429 rate limiting on getUploadURLExternal' do
        stub = stub_request(:post, get_upload_url)
               .with(body: { filename: 'test.txt', length: '5' },
                     headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
               .to_return(status: 429, body: 'Rate limited')

        Timecop.freeze do
          expect { run_action(base_input) }
            .to raise_error(IPaaS::Job::RescheduleJob,
                            "Slack API rate limit hit. 'Rate limited'") do |e|
            expect(e.reschedule_after).to eq(1.minute.from_now)
          end
          expect(stub).to have_been_requested.once
        end
      end

      it 'handles 429 rate limiting on file upload POST' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F123',
          }.to_json)

        post_stub = stub_request(:post, upload_url)
                    .to_return(status: 429, body: 'Rate limited')

        Timecop.freeze do
          expect { run_action(base_input) }
            .to raise_error(IPaaS::Job::RescheduleJob,
                            "Slack API rate limit hit. 'Rate limited'") do |e|
            expect(e.reschedule_after).to eq(1.minute.from_now)
          end
          expect(post_stub).to have_been_requested.once
        end
      end

      it 'handles 429 rate limiting on completeUploadExternal' do
        stub_request(:post, get_upload_url)
          .with(body: { filename: 'test.txt', length: '5' },
                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          .to_return(status: 200, body: {
            ok: true, upload_url: upload_url, file_id: 'F123',
          }.to_json)

        stub_request(:post, upload_url)
          .to_return(status: 200, body: 'OK')

        complete_stub = stub_request(:post, complete_url)
                        .to_return(status: 429, body: 'Rate limited',
                                   headers: { 'Retry-After' => '5' })

        Timecop.freeze do
          expect { run_action(base_input) }
            .to raise_error(IPaaS::Job::RescheduleJob,
                            "Slack API rate limit hit (retry after: 5). 'Rate limited'") do |e|
            expect(e.reschedule_after).to eq(5.seconds.from_now)
          end
          expect(complete_stub).to have_been_requested.once
        end
      end
    end
  end
end
