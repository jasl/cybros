class CreateConduitsLogChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_log_chunks, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :directive, type: :uuid, null: false,
                   foreign_key: { to_table: :conduits_directives }, index: true

      t.string  :stream,   null: false # stdout/stderr
      t.integer :seq,      null: false
      t.binary  :bytes,    null: false
      t.integer :bytesize, null: false
      t.boolean :truncated, null: false, default: false

      t.timestamps

      t.index %i[directive_id stream seq], unique: true,
              name: "index_conduits_log_chunks_uniqueness"
      t.index %i[created_at id],
              name: "index_conduits_log_chunks_on_created_at_and_id"
    end
  end
end
