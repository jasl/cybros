class LLMProvidersController < ApplicationController
  before_action :require_authentication
  before_action :set_llm_provider, only: %i[edit update destroy fetch_models]

  def index
    @llm_providers = LLMProvider.order(priority: :desc, created_at: :asc)
  end

  def new
    @llm_provider = LLMProvider.new(api_format: "openai", priority: 0, model_allowlist: [], headers: {})
  end

  def create
    attrs, errors = llm_provider_attributes_and_errors_from_params(existing_headers: {})
    @llm_provider = LLMProvider.new(attrs)
    errors.each { |(field, message)| @llm_provider.errors.add(field, message) }
    @headers_json = params.dig(:llm_provider, :headers_json).to_s

    if errors.empty? && @llm_provider.save
      flash[:notice] = "Provider created"
      redirect_to edit_llm_provider_path(@llm_provider)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attrs, errors = llm_provider_attributes_and_errors_from_params(existing_headers: @llm_provider.headers || {})
    attrs.delete(:api_key) if attrs.key?(:api_key) && attrs[:api_key].to_s.strip == ""
    @headers_json = params.dig(:llm_provider, :headers_json).to_s

    if errors.any?
      @llm_provider.assign_attributes(attrs)
      errors.each { |(field, message)| @llm_provider.errors.add(field, message) }
      render :edit, status: :unprocessable_entity
      return
    end

    if @llm_provider.update(attrs)
      flash[:notice] = "Provider updated"
      redirect_to edit_llm_provider_path(@llm_provider)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @llm_provider.destroy!
    flash[:notice] = "Provider deleted"
    redirect_to llm_providers_path
  end

  def fetch_models
    ids = LLMProviders::ModelFetcher.model_ids_for(@llm_provider)
    @llm_provider.update!(model_allowlist: ids)
    flash[:notice] = "Fetched #{ids.length} models"
    redirect_to edit_llm_provider_path(@llm_provider)
  rescue StandardError
    flash[:alert] = "Failed to fetch models"
    redirect_to edit_llm_provider_path(@llm_provider)
  end

  private

    def set_llm_provider
      @llm_provider = LLMProvider.find(params[:id])
    end

    def llm_provider_attributes_and_errors_from_params(existing_headers:)
      raw = params.require(:llm_provider).permit(
        :name,
        :base_url,
        :api_key,
        :api_format,
        :priority,
        :headers_json,
        :model_allowlist_text,
        model_allowlist: [],
      )

      attrs = raw.to_h
      errors = []

      if attrs.key?("priority")
        attrs["priority"] = Integer(attrs["priority"], exception: false)
      end

      if attrs.key?("model_allowlist_text")
        text = attrs.delete("model_allowlist_text").to_s
        models =
          text
            .lines
            .map { |l| l.strip }
            .reject(&:blank?)
            .uniq
        attrs["model_allowlist"] = models
      end

      if attrs.key?("headers_json")
        json = attrs.delete("headers_json").to_s.strip
        if json.blank?
          attrs["headers"] = {}
        else
          begin
            parsed = JSON.parse(json)
            attrs["headers"] = parsed.is_a?(Hash) ? parsed : {}
          rescue JSON::ParserError
            attrs["headers"] = existing_headers
            errors << [:headers, "must be valid JSON"]
          end
        end
      end

      [attrs.symbolize_keys, errors]
    end
end
