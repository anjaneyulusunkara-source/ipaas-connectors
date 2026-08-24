module Legacy
  class RemovedSecret
    attr_accessor :encrypted, :encryptor

    def initialize(encrypted = 'gAAAA_blob==')
      self.encrypted = encrypted
      self.encryptor = nil
    end
  end
end
