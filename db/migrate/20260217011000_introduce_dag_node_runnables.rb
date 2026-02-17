class IntroduceDAGNodeRunnables < ActiveRecord::Migration[8.2]
  def up
    create_table :dag_runnables_texts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.text :content
      t.timestamps
    end

    create_table :dag_runnables_tasks, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.text :content
      t.timestamps
    end

    add_reference :dag_nodes, :runnable, type: :uuid, polymorphic: true, null: true, index: false
    add_index :dag_nodes, %i[runnable_type runnable_id], unique: true, name: "index_dag_nodes_on_runnable_unique"

    say_with_time "Backfilling dag_nodes runnable references" do
      backfill_node_runnables
    end

    change_column_null :dag_nodes, :runnable_type, false
    change_column_null :dag_nodes, :runnable_id, false

    remove_column :dag_nodes, :content, :text
  end

  def down
    add_column :dag_nodes, :content, :text

    say_with_time "Backfilling dag_nodes content from runnables" do
      execute <<~SQL.squish
        UPDATE dag_nodes
        SET content = t.content
        FROM dag_runnables_texts t
        WHERE dag_nodes.runnable_type = 'DAG::Runnables::Text'
          AND dag_nodes.runnable_id = t.id
      SQL

      execute <<~SQL.squish
        UPDATE dag_nodes
        SET content = t.content
        FROM dag_runnables_tasks t
        WHERE dag_nodes.runnable_type = 'DAG::Runnables::Task'
          AND dag_nodes.runnable_id = t.id
      SQL
    end

    remove_index :dag_nodes, name: "index_dag_nodes_on_runnable_unique"
    remove_reference :dag_nodes, :runnable, polymorphic: true, type: :uuid

    drop_table :dag_runnables_tasks
    drop_table :dag_runnables_texts
  end

  private

    def backfill_node_runnables
      connection.select_all("SELECT id, node_type, content FROM dag_nodes WHERE runnable_id IS NULL").each do |row|
        node_id = row.fetch("id")
        node_type = row.fetch("node_type")
        node_content = row.fetch("content")

        if node_type == "task"
          runnable_id = insert_task_runnable(content: node_content)
          runnable_type = "DAG::Runnables::Task"
        else
          runnable_id = insert_text_runnable(content: node_content)
          runnable_type = "DAG::Runnables::Text"
        end

        execute <<~SQL.squish
          UPDATE dag_nodes
          SET runnable_type = #{connection.quote(runnable_type)},
              runnable_id = #{connection.quote(runnable_id)}
          WHERE id = #{connection.quote(node_id)}
        SQL
      end
    end

    def insert_text_runnable(content:)
      connection.select_value(<<~SQL.squish)
        INSERT INTO dag_runnables_texts (content, created_at, updated_at)
        VALUES (#{connection.quote(content)}, NOW(), NOW())
        RETURNING id
      SQL
    end

    def insert_task_runnable(content:)
      connection.select_value(<<~SQL.squish)
        INSERT INTO dag_runnables_tasks (content, created_at, updated_at)
        VALUES (#{connection.quote(content)}, NOW(), NOW())
        RETURNING id
      SQL
    end
end
