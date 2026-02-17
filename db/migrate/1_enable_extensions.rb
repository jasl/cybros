class EnableExtensions < ActiveRecord::Migration[8.2]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
    enable_extension "vector" unless extension_enabled?("vector")
  end
end
