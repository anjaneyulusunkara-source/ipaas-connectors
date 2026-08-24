module UnresolvedNodeHelper
  UNPERMITTED_CLASS = 'Legacy::RemovedSecret'.freeze

  def unpermitted_secret(ciphertext = 'gAAAA_blob==')
    Legacy::RemovedSecret.new(ciphertext)
  end

  def unpermitted_mapping_yaml(ciphertext = 'gAAAA_blob==', key: 'v')
    "#{key}: !ruby/object:#{UNPERMITTED_CLASS}\n  encrypted: #{ciphertext}\n  encryptor:\n"
  end

  def unpermitted_sequence_yaml(key: 'v')
    "#{key}: !ruby/array:#{UNPERMITTED_CLASS}\n- 0755\n- yes\n- null\n"
  end

  def dump_unresolved(node)
    IPaaS::Connector::Common::Serializer.dump({ 'v' => node }).delete_prefix("---\n")
  end

  def unresolved_node(ciphertext = 'gAAAA_blob==')
    IPaaS::Connector::Common::Serializer.parse(unpermitted_mapping_yaml(ciphertext), tolerant: true)['v']
  end
end

RSpec.configure { |config| config.include UnresolvedNodeHelper }
