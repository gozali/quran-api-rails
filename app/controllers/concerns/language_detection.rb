module LanguageDetection
  extend ActiveSupport::Concern

  included do
    attr_reader :indices_boost
    before_filter :determine_languages_boost
  end

  def determine_languages_boost
    boost_language_code = Hash.new
    @indices_boost = Hash.new

    # handle the accept-language http header
    if headers[ 'Accept-Language' ]
        Rails.logger.info "accept language headers #{ ap headers[ 'Accept-Language' ] }"
        # e.g. "en-US,en;q=0.8,ar;q=0.6"
        headers[ 'Accept-Language' ].split( /,/ ).map { |str| str.split( /;/ )[0].split( /-/ )[0] }.each do |lc|
            if not boost_language_code[ lc ]
                boost_language_code[ lc ] = 4
            else
                boost_language_code[ lc ] = boost_language_code[ lc ] + 1
            end
        end
    end

    # handle the country code determined from their geolocation
    if session[ 'country_code' ]
        # TODO this is NOT how we're going to do thiاللَّهُ نُورُs
        country_to_language_code = {}
        File.open( '/usr/share/i18n/SUPPORTED' ).each do |line|
            line.gsub! /[ .@].*/, ''
            lc, cc = line.split( /_/ )
            country_to_language_code[ cc ] = lc if not country_to_language_code[ cc ]
        end

        if country_to_language_code.key? session[ 'country_code' ]
            lc = country_to_language_code[ session[ 'country_code' ] ]
            if not boost_language_code[ lc ]
                boost_language_code[ lc ] = 4
            else
                boost_language_code[ lc ] = boost_language_code[ lc ] + 1
            end
        end
    end

    # handle the language code if say sometime in the future we allow users
    # to specify their preferred language directly in their settings
    if session[ 'language_code' ]
        lc = session[ 'language_code' ]
        if boost_language_code.keys.length > 0
            # just give it double score because they chose it explicitly
            boost_language_code[ lc ] = boost_language_code.values.max * 2
        else
            boost_language_code[ lc ] = 4
        end
    end

    # fallback to doubling the boost on english queries if we haven't gotten anywhere
    # using the above strategies and the query is pure ascii
    if boost_language_code.keys.length == 0 and params[:q] =~ /^(?:\s*\p{ASCII}+\s*)+$/
        boost_language_code[ 'en' ] = 4
    end


    boost_language_code.keys.each do |lc|
        @indices_boost[ :"translation-#{lc}" ] = boost_language_code[ lc ]
    end

    Rails.logger.ap @indices_boost
    return @indices_boost
  end
end