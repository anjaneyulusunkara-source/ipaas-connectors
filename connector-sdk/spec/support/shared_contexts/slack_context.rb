shared_context 'slack', :slack do
  let(:connector_id) { '019d6e9d-90c5-724f-840b-13cb467ff342' }
  let(:outbound_connection_config) do
    {
      bearer: {
        bearer_token: make_secret_string('xoxb-test-token'),
      },
    }
  end
  let(:slack_api) { 'https://slack.com/api' }
end
