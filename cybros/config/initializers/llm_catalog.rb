require Rails.root.join("lib/cybros/llm/catalog")
require Rails.root.join("lib/cybros/llm/codex_oauth")
require Rails.root.join("lib/cybros/llm/capability_gated_provider")
require Rails.root.join("lib/cybros/statistics/usage_stats")

begin
  Cybros::LLM::Catalog.effective
rescue Cybros::LLM::CatalogError => e
  raise e
rescue StandardError => e
  raise Cybros::LLM::CatalogError.new("Failed to load LLM catalog: #{e.class}: #{e.message}")
end
