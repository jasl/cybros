class AdjustActiveStorageAttachmentRecordIdsToUuid < ActiveRecord::Migration[8.1]
  def up
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_uniqueness"
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_on_blob_id"

    execute "DELETE FROM active_storage_variant_records"
    execute "DELETE FROM active_storage_attachments"
    execute "DELETE FROM active_storage_blobs"

    remove_column :active_storage_attachments, :record_id, :bigint
    add_column :active_storage_attachments, :record_id, :uuid, null: false

    add_index :active_storage_attachments, :blob_id, name: "index_active_storage_attachments_on_blob_id"
    add_index :active_storage_attachments, [:record_type, :record_id, :name, :blob_id], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  def down
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_uniqueness"
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_on_blob_id"

    execute "DELETE FROM active_storage_variant_records"
    execute "DELETE FROM active_storage_attachments"
    execute "DELETE FROM active_storage_blobs"

    remove_column :active_storage_attachments, :record_id, :uuid
    add_column :active_storage_attachments, :record_id, :bigint, null: false

    add_index :active_storage_attachments, :blob_id, name: "index_active_storage_attachments_on_blob_id"
    add_index :active_storage_attachments, [:record_type, :record_id, :name, :blob_id], name: "index_active_storage_attachments_uniqueness", unique: true
  end
end
