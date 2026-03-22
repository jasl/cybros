class AdjustActiveStorageVariantRecordIdsToUuid < ActiveRecord::Migration[8.2]
  def up
    variant_blob_ids =
      select_values(<<~SQL.squish)
        SELECT blob_id
        FROM active_storage_attachments
        WHERE record_type = 'ActiveStorage::VariantRecord'
      SQL

    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'ActiveStorage::VariantRecord'
    SQL

    if variant_blob_ids.any?
      execute <<~SQL.squish
        DELETE FROM active_storage_blobs
        WHERE id IN (#{variant_blob_ids.map { |id| connection.quote(id) }.join(", ")})
      SQL
    end

    drop_table :active_storage_variant_records

    create_table :active_storage_variant_records, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.belongs_to :blob, null: false, index: false, type: :bigint
      t.string :variation_digest, null: false

      t.index [:blob_id, :variation_digest], name: :index_active_storage_variant_records_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end

  def down
    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'ActiveStorage::VariantRecord'
    SQL

    drop_table :active_storage_variant_records

    create_table :active_storage_variant_records do |t|
      t.belongs_to :blob, null: false, index: false, type: :bigint
      t.string :variation_digest, null: false

      t.index [:blob_id, :variation_digest], name: :index_active_storage_variant_records_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end
end
