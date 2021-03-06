module SteamWebApi

  class Dota2
    class Refresh
      # Singleton
      class << self

        def define_refresh_method(klass)
          name = klass.name.downcase.pluralize
          define_singleton_method("refresh_#{name}") do
            # used for activerecord-import for bulk inserting data
            new_records = []
            puts "Fetching #{name}..."
            data_from_api, status =  ApiCall.send "get_#{name}"
            # Check if API call was successful
            if status == 200
              records_from_db = klass.all.try(:index_by, &:steam_id)

              data_from_api.each do |api_data|
                if db_record = records_from_db[api_data.id.to_i]
                  db_record.update_status(api_data)
                  db_record.save if db_record.changed?
                # Let's create a new record since id wasn't found in db
                else
                  # Prepare api data for mass assignment
                  api_data.steam_id = api_data.delete(:id)
                  new_records << klass.new(api_data.to_hash)
                end
              end
              puts "Saving updated #{name} into db..."
              # Save records in db using activerecord-import method
              klass.import new_records if new_records.any?
              puts "Done!"
            end
          end
        end
      end

      # Define refresher methods for Hero, Item and Ability
      define_refresh_method Hero
      define_refresh_method Item
      define_refresh_method Ability
    end

    class Fetch

      # Singleton
      class << self

        def fetch_last_league_matches
          # Check if there are any records in the db
          # in order to use the last match seq number
          if last_match_seq_num = Match.order("match_seq_num DESC").try(:first).try(:match_seq_num)
            get_league_matches(last_match_seq_num + 1)
          # Database is empty so let's fill it
          else
            get_league_matches
          end
        end

        def fetch_live_league_matches
          puts "Fetching live matches..."
          live_matches, status = ApiCall::get_live_league_matches
          live_match_ids = live_matches.map(&:match_id)
          if status == 200
            if Rails.cache.exist?('live_match_ids')
              finished_match_ids = Rails.cache.read('live_match_ids') - live_match_ids
              if finished_match_ids.any?
                puts "Saving finished matches into db..."
                finished_matches = []
                finished_match_ids.each do |id|
                  finished_matches << LiveLeagueMatch.new(Rails.cache.read('live_matches')[id].to_hash)
                end
                LiveLeagueMatch.import finished_matches if finished_matches.any?
                puts "Done!"
              end
            end
            Rails.cache.write 'live_matches', live_matches.index_by(&:match_id)
            Rails.cache.write 'live_match_ids', live_match_ids
          end
        end

        def fetch_leagues
          api_leagues = ApiCall::get_leagues
          if api_leagues.any?
            league_records = []
            leagues_from_db = League.all.try(:index_by, &:leagueid)
            api_leagues.each do |api_league|
              if db_league = leagues_from_db[api_league.leagueid]
                db_league.update_status(api_league)
                db_league.save if db_league.changed?
              else
                league_records << League.new(api_league.to_hash)
              end
            end
            League.import(league_records, validate: false) if league_records.any?
          end
        end

        private

          # The real work horse which gets matches from the Steam Web API
          # and bulk saves them in the db.
          def get_league_matches(match_seq_num=nil)
            fetched_matches = []
            matches, status = ApiCall::get_matches_by_seq_num(match_seq_num)
            # status:
            # 1 - Success
            # 8 - 'matches_requested' must be greater than 0.
            # Ref. https://wiki.teamfortress.com/wiki/WebAPI/GetMatchHistoryBySequenceNum
            while status == 1 && matches.any?
              puts "Fetching matches..."
              matches.each do |match|
                # We only want to fetch league matches
                if match.leagueid != 0
                  # We wanna convert start time from unix time stamp to DateTime first
                  match["start_time"] = Time.at(match["start_time"]).utc
                  fetched_matches << Match.new(match.to_hash)
                end
              end
              puts "Matches fetched: #{fetched_matches.count}"
              puts "Saving matches into db..."
              Match.import(fetched_matches, validate: false) if fetched_matches.any?
              puts "Done!"
              fetched_matches.clear
              # Let's see if there are more matches to fetch. Since we don't want to save
              # any records twice we query the API using highest seq number + 1
              next_seq_num = matches.map(&:match_seq_num).max + 1
              puts "Next match seq number: #{next_seq_num}"
              matches, status = ApiCall::get_matches_by_seq_num(next_seq_num)
            end
          end
      end
    end


    # Singleton class used for Api calls of the Steam Web Api
    class ApiCall
      include HTTParty
      base_uri 'api.steampowered.com'

      # Singleton
      class << self

        # Returns an array of Hashie::Mash objects representing the heroes
        # and int providing the status of the api call.
        def get_heroes
          api_result = Hashie::Mash.new(get("/IEconDOTA2_570/GetHeroes/v0001/?key=#{ENV["steam_web_api_key"]}&language=en_us"))
          return [api_result.result.heroes, api_result.result.status]
        end

        # Returns an array of Hashie::Mash objects representing the heroes
        # and int providing the status of the api call.
        def get_items
          api_result = Hashie::Mash.new(get("/IEconDOTA2_205790/GetGameItems/V001/?key=#{ENV["steam_web_api_key"]}&language=en_us"))
          return [api_result.result.items, api_result.result.status]
        end

        # Since the Steam Web Api doesn't offer an endpoint for the ability id's
        # we are using a json file with all the information.
        # Ref. http://dev.dota2.com/showthread.php?t=104192
        def get_abilities
          # We are using Mash.load since we read a local file
          ability_data = Hashie::Mash.load("#{Rails.root}/public/abilities.json")
          return [ability_data.result.abilities, ability_data.result.status]
        end

        # Returns an array of Hashie::Mash objects representing the leagues
        # supported in-game via DotaTV.
        def get_leagues
          api_result = Hashie::Mash.new(get("/IDOTA2Match_570/GetLeagueListing/v1?key=#{ENV["steam_web_api_key"]}"))
          return api_result.result.leagues
        end

        def get_live_league_matches
          api_result = Hashie::Mash.new(get("/IDOTA2Match_570/GetLiveLeagueGames/v1?key=#{ENV["steam_web_api_key"]}"))
          return [api_result.result.games, api_result.result.status]
        end

        def get_match(match_id)
          api_result = Hashie::Mash.new(get("/IDOTA2Match_570/GetMatchDetails/v1?key=#{ENV["steam_web_api_key"]}&match_id=#{match_id}"))
          return api_result
        end

        def get_matches_by_seq_num(match_seq_num=nil)
          api_result = Hashie::Mash.new(
              get("/IDOTA2Match_570/GetMatchHistoryBySequenceNum/v1?key=#{ENV["steam_web_api_key"]}&start_at_match_seq_num=#{match_seq_num}&language=en_us"))
          return [api_result.result.matches, api_result.result.status]
        end
      end
    end
  end
end