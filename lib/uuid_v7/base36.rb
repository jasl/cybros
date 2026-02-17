require "securerandom"

module UuidV7
  module Base36
    ID_LENGTH = 25

    def self.generate
      uuid_hex = SecureRandom.uuid_v7.delete("-")
      uuid_int = uuid_hex.to_i(16)
      uuid_int.to_s(36).rjust(ID_LENGTH, "0")
    end
  end
end
