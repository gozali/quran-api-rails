# vim: ts=4 sw=4 expandtab
# DONE 1. set analyzers for every language
# TODO 1.a. actually configure the analyzer so that certain words are protected (like allah, don't want to stem that). hopefully an alternate solution is available, so this isn't priority until the steps below are done.
# TODO 2. determine the language of the query (here)
# TODO 3. apply weights to different types of indices e.g. text > tafsir
# TODO 4. break down fields into analyzed and unanalyzed and weigh them
#
# NEW
# TODO 1. determine language
#      2. refactor query accordingly
#      3. refactor code
#      4. refine search, optimize for performance
require 'elasticsearch'

class SearchController < ApplicationController
    include LanguageDetection

    def query
        query = params[:q]
        page  = [ ( params[:page] or params[:p] or 1 ).to_i, 1 ].max
        size  = [ [ ( params[:size] or params[:s] or 20 ).to_i, 20 ].max, 40 ].min # sets the max to 40 and min to 20
        # Determining query language
        # - Determine if Arabic (regex); if not, determine boost using the following...
        #   a. Use Accept-Language HTTP header
        #   b. Use country-code to language mapping (determine country code from geolocation)
        #   c. Use language-code from user application settings (should get at least double priority to anything else)
        #   d. Fallback to boosting English if nothing was determined from above and the query is pure ascii

        # Rails.logger.info "headers #{ ap headers }"
        # Rails.logger.info "session #{ ap session }"
        # Rails.logger.info "params #{ ap params }"

        start_time = Time.now
        search_params = Hash.new
        most_fields_fields_val = Array.new

        if query =~ /^(?:\s*[\p{Arabic}\p{Diacritic}\p{Punct}\p{Digit}]+\s*)+$/
            search_params.merge!( {
                index: [ 'text-font', 'tafsir' ],
                body: {
                    indices_boost: {
                        :"text-font" => 4,
                        :"tafsir"    => 1
                    }
                }
            } )
            most_fields_fields_val = [
                'text^5',
                'text.lemma^4',
                'text.stem^3',
                'text.root^1.5',
                'text.lemma_clean^3',
                'text.stem_clean^2',
                'text.ngram^2',
                'text.stemmed^2'
            ]

        else
            most_fields_fields_val = [ 'text^1.6', 'text.stemmed' ]

            # TODO filter for langs that have translations only
            search_params.merge!( {
                index: [ 'trans*', 'text-font' ],
                body: {
                    indices_boost: @indices_boost #coming from language detection
                }
            } )

            # Determine if this is an AND/OR query
            if query.downcase.split('or').length > 1
              query_type = :or
              query_split = query.downcase.split('or')
            else
              query_type = :and
            end
        end

        search_params.merge!( {
            type: 'data',

            explain: false, # debugging... on or off?
        } )

        # highlighting
        search_params[:body].merge!( {
            highlight: {
                fields: {
                    text: {
                        type: 'fvh',
                        matched_fields: [ 'text.root', 'text.stem_clean', 'text.lemma_clean', 'text.stemmed', 'text' ],
                        ## NOTE this set of commented options highlights up to the first 100 characters only but returns the whole string
                        #fragment_size: 100,
                        #fragment_offset: 0,
                        #no_match_size: 100,
                        #number_of_fragments: 1
                        number_of_fragments: 0
                    }
                },
                tags_schema: 'styled',
                #force_source: true
            },
        } )

        # query
        bool = {}
        if query_type == :or
          bool[:should] = query_split.map do |q|
            {
              multi_match: {
                type: 'most_fields',
                query: q.strip,
                fields: most_fields_fields_val,
                minimum_should_match: '3<62%'
              }
            }
          end
        else
          bool[:must] = [{
            ## NOTE leaving this in for future reference
            #   terms: {
            #        :'ayah.surah_id' => [ 24 ]
            #        :'ayah.ayah_key' => [ '24_35' ]
            #    }
            #}, {
            multi_match: {
                type: 'most_fields',
                query: query,
                fields: most_fields_fields_val,
                minimum_should_match: '3<62%'
            }
          }]
        end
        search_params[:body].merge!( {
          query: {
            bool: bool
          },
        } )

        # other experimental stuff
        search_params[:body].merge!( {
            fields: [ 'ayah.ayah_key', 'ayah.ayah_num', 'ayah.surah_id', 'ayah.ayah_index', 'text' ],
            _source: [ "text", "ayah.*", "resource.*", "language.*" ],
        } )

        # aggregations
        search_params[:body].merge!( {
            aggs: {
                by_ayah_key: {
                    terms: {
                        field: "ayah.ayah_key",
                        size: 6236,
                        order: {
                            max_score: "desc"
                        }
                    },
                    aggs: {
                        max_score: {
                            max: {
                                script: "_score"
                            }
                        }
                    }
                }
            },
            size: 0
        } )

        #return search_params
        client = Elasticsearch::Client.new  # trace: true, log: true;
        results = client.search( search_params )

        total_hits = results['hits']['total']

        buckets = results['aggregations']['by_ayah_key']['buckets']

        imin = ( page - 1 ) * size
        imax = page * size - 1

        buckets_on_page = buckets[ imin .. imax ]
        keys = buckets_on_page.map { |h| h['key'] }

        doc_count = buckets_on_page.inject( 0 ) { |doc_count, h| doc_count + h[ 'doc_count' ] }


        #return buckets
        # restrict to keys on this page
        if search_params[:body][:query][:bool][:must].present?
          search_params[:body][:query][:bool][:must].unshift( {
            terms: {
                :'ayah.ayah_key' => keys
            }
          })
        else
          search_params[:body][:query][:bool][:must] = [{
            terms: {
                :'ayah.ayah_key' => keys
            }
          }]
        end

        # limit to the number of docs we know we want
        search_params[:body][:size] = doc_count

        # get rid of the aggregations
        search_params[:body].delete( :aggs )

        # pull the new query with hits
        results = client.search( search_params ).deep_symbolize_keys
        #return results



        # override experimental
        search_params_text_font = {
            index: [ 'text-font' ],
            type: 'data',
            explain: false,
            size: keys.length,
            body: {
                query: {
                    ids: {
                        type: 'data',
                        values: keys.map { |k| "1_#{k}" }
                    }
                }
            }
        }
        results_text_font = client.search( search_params_text_font ).deep_symbolize_keys
        ayah_key_to_font_text = results_text_font[:hits][:hits].map { |h| [ h[:_source][:ayah][:ayah_key], h[:_source][:text] ] }.to_h
        ayah_key_to_font_text = {}
        ayah_key_hash = {}

        by_key = {}

        results[:hits][:hits].each do |hit|
            _source    = hit[:_source]
            _score     = hit[:_score]
            _text = ( hit.key?( :highlight ) && hit[ :highlight ].key?( :text ) && hit[ :highlight ][ :text ].first.length ) ? hit[ :highlight ][ :text ].first : _source[ :text ]
            _ayah      = _source[:ayah]

            by_key[ _ayah[:ayah_key] ] = {
                  key: _ayah[:ayah_key],
                 ayah: _ayah[:ayah_num],
                surah: _ayah[:surah_id],
                index: _ayah[:ayah_index],
                score: 0,
                match: {
                    hits: 0,
                    best: []
                }
            } if by_key[ _ayah[:ayah_key] ] == nil

            #quran = by_key[ _ayah[ 'ayah_key' ] ][:bucket][:quran]
            result = by_key[ _ayah[:ayah_key] ]

            # TODO: transliteration does not have a resource or language.
            #id name slug text lang dir
            extension = {
                text: _text,
                score: _score,
            }.merge( _source[:resource] ? {
                id: _source[:resource][:resource_id],
                name: _source[:resource][:name],
                slug: _source[:resource][:slug],
                lang: _source[:resource][:language_code],
            } : {name: 'Transliteration'} )
            .merge( _source[:language] ? {
                dir: _source[:language][:direction],
            } : {} )
#            .merge( { debug: hit } )

            if hit[:_index] == 'text-font' && _text.length
                extension[:_do_interpolate] = true
            end

            result[:score]        = _score if _score > result[:score]
            result[:match][:hits] = result[:match][:hits] + 1
            result[:match][:best].push( {}.merge!( extension ) ) # if result[:match][:best].length < 3
        end

        word_id_hash = {}
        word_id_to_highlight = {}

        # attribute the "bucket" structure for each ayah result
        by_key.values.each do |result|

            # result[:bucket] = Quran::Ayah.get_ayat( { surah_id: result[:surah], ayah: result[:ayah], content: params[:content], audio: params[:audio] } ).first

            # if result[:bucket][:content]
            #     resource_id_to_bucket_content_index = {}
            #     result[:bucket][:content].each_with_index do | c, i |
            #         resource_id_to_bucket_content_index[ c[:id].to_i ] = i
            #     end
            #
            #     #
            #     result[:match][:best].each do |b|
            #         id = b[:id].to_i
            #
            #         if index = resource_id_to_bucket_content_index[ id ]
            #             result[:bucket][:content][ index ][:text] = b[:text]
            #         end
            #     end
            # end

            result.merge!(Quran::Ayah.get_ayat( { surah_id: result[:surah], ayah: result[:ayah], content: params[:content], audio: params[:audio] } ).first.as_json.deep_symbolize_keys)
            if result[:content]
                resource_id_to_bucket_content_index = {}
                result[:content].each_with_index do | c, i |
                    resource_id_to_bucket_content_index[ c[:id].to_i ] = i
                end

                #
                result[:match][:best].each do |b|
                    id = b[:id].to_i

                    if index = resource_id_to_bucket_content_index[ id ]
                        result[:content][ index ][:text] = b[:text]
                    end
                end
            end

            result[:match][:best].each do |h|
                if h.delete( :_do_interpolate )
                    t = h[:text].split( '' )
                    parsed = { word_ids: [] }
                    for i in 0 .. t.length - 1
                        # state logic
                        # if its in a highlight tag
                            # if its in the class value
                        # if its in a word id
                            # if its a start index
                            # if its an end index
                        # if its highlighted
                        parsed[:a_number] = t[i].match( /\d/ ) ? true : false
                        parsed[:a_start_index] = false
                        parsed[:an_end_index] = false

                        if not parsed[:in_highlight_tag] and t[i] == '<'
                            parsed[:in_highlight_tag] = true
                        elsif parsed[:in_highlight_tag] and t[i] == '<'
                            parsed[:in_highlight_tag] = false
                        end

                        if parsed[:in_highlight_tag] and not parsed[:in_class_value] and t[i-1] == '"' and t[i-2] == '='
                            parsed[:in_class_value] = true
                        elsif parsed[:in_highlight_tag] and parsed[:in_class_value] and t[i] == '"'
                            parsed[:in_class_value] = false
                        end

                        if parsed[:a_number] and ( i == 0 or ( t[i-1] == ' ' or t[i-1] == '>' ) )
                            parsed[:in_word_id] = true
                            parsed[:a_start_index] = true
                        elsif not parsed[:a_number] and parsed[:in_word_id]
                            parsed[:in_word_id] = false
                        end

                        if parsed[:in_word_id] and ( i == t.length - 1 or ( t[i+1] == ' ' or t[i+1] == '<' ) )
                            parsed[:an_end_index] = true
                        end

                        # control logic
                        if i == 0
                            parsed[:current] = { word_id: [], indices: [], highlight: [] }
                        end


                        if parsed[:in_class_value]
                            parsed[:current][:highlight].push( t[i] )
                        end

                        if parsed[:in_word_id]

                            parsed[:current][:word_id].push( t[i] )

                            if parsed[:a_start_index]
                                parsed[:current][:indices][0] = i
                            end

                            if parsed[:an_end_index]
                                parsed[:current][:indices][1] = i
                                parsed[:current][:word_id] = parsed[:current][:word_id].join( '' )
                                parsed[:current][:highlight] = parsed[:current][:highlight].join( '' )
                                if not parsed[:current][:highlight].length > 0
                                    parsed[:current].delete( :highlight )
                                end

                                if parsed[:current].key?( :highlight )
                                    word_id_to_highlight[ parsed[:current][:word_id].to_i ] = parsed[:current][:highlight] #true
                                end

                                parsed[:word_ids].push( parsed[:current] )
                                parsed[:current] = { word_id: [], indices: [], highlight: [] }
                            end
                        end
                    end

                    if parsed[:word_ids].length > 0
                        # init the word_id_hash

                        result[:quran].each do |h|
                            word_id_hash[ h[:word][:id].to_s.to_sym ] = { text: h[:word][:arabic] } if h[:word][:id]
                            if word_id_to_highlight.key? h[:word][:id].to_i
                                h[:highlight] = word_id_to_highlight[ h[:word][:id] ]
                            end
                        end

                        parsed[:word_ids].each do |p|
                            word_id = p[:word_id] #.delete :word_id
                            word_id_hash[ word_id.to_s.to_sym ].merge!( p )
                        end
                    end

                    word_id_hash.each do |id,h|
                        for i in h[:indices][0]  .. h[:indices][1]
                            t[i] = nil
                        end
                        t[ h[:indices][0] ] = h[:text]
                    end
                    h[:text] = t.join( '' )
                end
            end
        end

        return_result = by_key.keys.sort {|a,b| by_key[ b ][ :score ] <=> by_key[ a ][ :score ] } .map { |k| by_key[ k ] }

        # HACK: a block of transformation hacks
        return_result.map! do |r|
            # HACK: move back from '2_255' ayah_key format (was an experimental change b/c of ES acting weird) to '2:255'
            r[:key].gsub! /_/, ':'
            # HACK: a bit of a hack, or just keeping redundant info tidy? removing redundant keys from the 'bucket' property (I really want to rename that property)
            # r[:bucket].delete :surah
            # r[:bucket].delete :ayah
            # r[:quran].map! do |q|
            #     q.delete :ayah_key
            #     q.delete :word if q[:word] and q[:word][:id] == nil # get rid of the word block if its just a bunch of nils
            #     q
            # end
            r[:match][:best] = r[:match][:best][ 0 .. 2 ] # top 3
            r
        end

        delta_time = Time.now - start_time

        render json: {
            query: params[:q],
            hits: return_result.length,
            page: page,
            size: size,
            took: delta_time,
            total: buckets.length,
            results: return_result
        }
    end
end
