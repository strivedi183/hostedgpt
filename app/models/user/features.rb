class User::Features
  # The transport opinions a backend choice can hold; "" (blank) means
  # "inherit the site default".
  BACKEND_CHOICES = %w[ruby_llm sdk].freeze

  # One row per chat provider identity (see APIService.chat_provider_identities):
  # brave has no chat backend, and Groq and OpenRouter get their own names
  # because they ride the openai driver.
  def self.derived_backend_names
    APIService.chat_provider_identities.map { |identity| :"#{identity}_ai_backend" }
  end

  def self.valid_names
    derived_backend_names + [:use_ruby_llm]
  end

  def self.ruby_llm_available?(identity)
    defined?(AIBackend::RubyLLM) &&
      AIBackend::RubyLLM.respond_to?(:supports_identity?) &&
      AIBackend::RubyLLM.supports_identity?(identity)
  end

  def initialize(user)
    @user = user
  end

  def [](name)
    key = guard_name!(name)
    feature_preferences[key]
  end

  def []=(name, value)
    key = guard_name!(name)
    @user.update!(preferences: @user.preferences.deep_merge(feature: { key => value }))
  end

  private

  def feature_preferences
    sub_hash = @user.preferences[:feature] || @user.preferences["feature"] || {}
    sub_hash.transform_keys(&:to_sym)
  end

  def guard_name!(name)
    key = name.to_s.chomp("=").to_sym
    unless self.class.valid_names.include?(key)
      raise KeyError, "You attempted to reference '#{key}' but only AI-backend choices (<backend>_ai_backend) and use_ruby_llm are accessible here. Did you typo a feature name?"
    end

    key
  end
end
