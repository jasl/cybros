class CreateNodePayloads < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_node_payloads, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :type, null: false
      t.jsonb :input, null: false, default: {}
      t.jsonb :output, null: false, default: {}
      t.jsonb :output_preview, null: false, default: {}

      t.timestamps
    end

    change_table :dag_nodes do |t|
      t.references :payload, type: :uuid, null: false,
        foreign_key: { to_table: :dag_node_payloads },
        index: { unique: true }
    end
  end
end
