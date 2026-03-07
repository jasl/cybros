#!/usr/bin/env ruby
abort <<~MSG
  DEPRECATED: `script/diagnose_retry_400.rb` has been retired.

  Use the unified DAG debug CLI instead:

    bin/rails runner script/dag_debug.rb inspect <node_id>
    bin/rails runner script/dag_debug.rb context <node_id>
    bin/rails runner script/dag_debug.rb capture <node_id> --execute

  `capture` is now the primary tool for provider payload / error debugging.
MSG
