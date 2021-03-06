class OptionsController < ApplicationController
  # caches_page :default, :language, :quran, :content, :audio
  caches_action :default, :language, :quran, :content, :audio
  def default
    @results = {content: [21], quran: 1, audio: 1, url: "?content=217&quran=1&audio=1"}
  end

  def language
    @results = Content::Resource.list_language_options
  end

  def quran
    @results = Content::Resource.list_quran_options
  end

  def content
    @results = Content::Resource.list_content_options
  end

  def audio
    @results = Audio::Recitation.list_audio_options
  end
end
