class Account < ApplicationRecord
  def self.instance
    first_or_create!
  end

  def llm_default_model_ref
    settings.dig("llm", "default_model_ref").to_s.presence
  end

  def update_llm_default_model_ref!(model_ref)
    next_settings = settings.is_a?(Hash) ? settings.deep_dup : {}
    llm_settings = next_settings["llm"].is_a?(Hash) ? next_settings["llm"].deep_dup : {}

    ref = model_ref.to_s.strip
    if ref.empty?
      llm_settings.delete("default_model_ref")
    else
      llm_settings["default_model_ref"] = ref
    end

    if llm_settings.empty?
      next_settings.delete("llm")
    else
      next_settings["llm"] = llm_settings
    end

    update!(settings: next_settings)
  end
end
