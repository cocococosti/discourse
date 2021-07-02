# frozen_string_literal: true

require "mysql2"
require 'time'
require 'date'

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::FLARUM < ImportScripts::Base
  #SET THE APPROPRIATE VALUES FOR YOUR MYSQL CONNECTION
  FLARUM_HOST ||= ENV['FLARUM_HOST'] || "localhost"
  FLARUM_DB ||= ENV['FLARUM_DB'] || "flarum_ajalan"
  BATCH_SIZE ||= 1000
  FLARUM_USER ||= ENV['FLARUM_USER'] || "db_host"
  FLARUM_PW ||= ENV['FLARUM_PW'] || "db_name"
  UPLOADS_DIR ||= "/Users/constanza/Downloads/flarum/avatars"

  def initialize
    super
    @use_bbcode_to_md = true

    @client = Mysql2::Client.new(
      host: FLARUM_HOST,
      username: FLARUM_USER,
      password: FLARUM_PW,
      database: FLARUM_DB
    )
  end

  def execute

    import_users
    import_categories
    import_posts
    create_permalinks

  end

  def import_users
    puts '', "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT id, username, email, joined_at, last_seen_at, avatar_url
         FROM users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};")

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        { id: user['id'],
          email: user['email'],
          username: user['username'],
          name: user['username'],
          created_at: user['joined_at'],
          last_seen_at: user['last_seen_at'],
          post_create_action: lambda do |newmember|
            if user['avatar_url'].present? && newmember.uploaded_avatar_id.blank?
              path, filename = File.join(UPLOADS_DIR, user["avatar_url"])
              if path
                begin
                  upload = create_upload(newmember.id, path, filename)
                  if !upload.nil? && upload.persisted?
                    newmember.import_mode = false
                    newmember.create_user_avatar
                    newmember.import_mode = true
                    newmember.user_avatar.update(custom_upload_id: upload.id)
                    newmember.update(uploaded_avatar_id: upload.id)
                  else
                    puts "Error: Upload did not persist!"
                  end
                rescue SystemCallError => err
                  puts "Could not import avatar: #{err.message}"
                end
              end
            end
          end
        }
      end
    end
  end

  def import_categories
    puts "", "importing top level categories..."

    categories = mysql_query("
                              SELECT id, name, description, position
                              FROM tags
                              ORDER BY position ASC
                            ").to_a

    create_categories(categories) do |category|
      {
        id: category["id"],
        name: category["name"]
      }
    end

    puts "", "importing children categories..."

    children_categories = mysql_query("
                                       SELECT id, name, description, position
                                       FROM tags
                                       ORDER BY position
                                      ").to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category['id']}",
        name: category["name"],
        description: category["description"],
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.id id,
               d.id topic_id,
               d.title title,
               d.first_post_id first_post_id,
               p.user_id user_id,
               p.content raw,
               p.created_at created_at,
               t.tag_id category_id
        FROM posts p,
             discussions d,
             discussion_tag t
        WHERE p.discussion_id = d.id
          AND t.discussion_id = d.id
        ORDER BY p.created_at
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ").to_a

      # results.each do |x|
      #   if x['title'] == 'The lobotomized owl CSS trick' then 
      #     puts process_FLARUM_post(x['raw'], x['id'])
      #   end
      # end
      # exit

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m['id'].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['user_id']) || -1
        mapped[:raw] = process_FLARUM_post(m['raw'], m['id'])
        mapped[:created_at] = Time.zone.at(m['created_at'])

        if m['id'] == m['first_post_id']
          mapped[:category] = category_id_from_imported_category_id("child##{m['category_id']}")
          mapped[:title] = CGI.unescapeHTML(m['title'])
        else
          parent = topic_lookup_from_imported_post_id(m['first_post_id'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m['first_post_id']} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def process_FLARUM_post(raw, import_id)
    s = raw.dup

    # truncate line space, preventing line starting with many blanks to be parsed as code blocks
    s.gsub!(/^ {4,}/, '   ')

    s.gsub!(/\[email\]([^\]]*)\[\/email\]/i, '[url=mailto:\1]\1[/url]') # bbcode-to-md can convert it
    s.gsub!(/\[sup\]([^\]]*)\[\/sup\]/i, '<sup>\1</sup>')
    s.gsub!(/\[sub\]([^\]]*)\[\/sub\]/i, '<sub>\1</sub>')
    s.gsub!(/\[hr\]/i, "\n---\n")
    # [br]
    s.gsub!(/\[br\]/i, "\n")
    s.gsub!(/<br\s*\/?>/i, "\n")

    # I don't know what this is, it is always used with <h3>
    s.gsub!(/<s>### <\/s>/, '')

    # I don't know what this is either
    s.gsub!(/<r>/, '')
    s.gsub!(/<\/r>/, '')

    # This is not necessary in discourse I think
    s.gsub!(/<p>/, '')
    s.gsub!(/<\/p>/, '')

    # [i]
    s.gsub!(/\[i\]/i, "<em>")
    s.gsub!(/\[\/i\]/i, "</em>")
    s.gsub!(/\[u\]/i, "<em>")
    s.gsub!(/\[\/u\]/i, "</em>")
    #[b]
    s.gsub!(/\[b\]([^\]]*)\[\/b\]/i, '<b>\1</b>')
    # [pre]
    s.gsub!(/\[pre\]([^\]]*)\[\/pre\]/i, '<pre>\1</pre>')

    # Remove the media tag
    s.gsub!(/\[\/?media[^\]]*\]/i, "\n")
    s.gsub!(/\[\/?flash[^\]]*\]/i, "\n")
    s.gsub!(/\[\/?audio[^\]]*\]/i, "\n")
    s.gsub!(/\[\/?video[^\]]*\]/i, "\n")

    # Remove the font, p and backcolor tag
    # Discourse doesn't support the font tag
    s.gsub!(/\[font=[^\]]*?\]/i, '')
    s.gsub!(/\[\/font\]/i, '')
    s.gsub!(/\[p=[^\]]*?\]/i, '')
    s.gsub!(/\[\/p\]/i, '')
    s.gsub!(/\[backcolor=[^\]]*?\]/i, '')
    s.gsub!(/\[\/backcolor\]/i, '')

    # Remove the size tag
    s.gsub!(/\[size=[^\]]*?\]/i, '')
    s.gsub!(/\[\/size\]/i, '')

    # Remove the color tag
    s.gsub!(/\[color=[^\]]*?\]/i, '')
    s.gsub!(/\[\/color\]/i, '')

    # Remove the hide tag
    s.gsub!(/\[\/?hide\]/i, '')
    s.gsub!(/\[\/?free[^\]]*\]/i, "\n")

    # Remove the align, float, left, right and center tags
    s.gsub!(/\[align=[^\]]*?\]/i, "\n")
    s.gsub!(/\[align\]/i, "\n")
    s.gsub!(/\[\/align\]/i, "\n")
    s.gsub!(/\[float=[^\]]*?\]/i, "\n")
    s.gsub!(/\[\/float\]/i, "\n")
    s.gsub!(/\[float\]/i, "\n")
    s.gsub!(/\[right=[^\]]*?\]/i, "\n")
    s.gsub!(/\[\/right\]/i, "\n")
    s.gsub!(/\[right\]/i, "\n")
    s.gsub!(/\[left=[^\]]*?\]/i, "\n")
    s.gsub!(/\[\/left\]/i, "\n")
    s.gsub!(/\[left\]/i, "\n")
    s.gsub!(/\[center=[^\]]*?\]/i, "\n")
    s.gsub!(/\[\/center\]/i, "\n")
    s.gsub!(/\[center\]/i, "\n")

    s.gsub!(/<br>/, "\n\n")
    s.gsub!(/<br \/>/, "\n\n")
    s.gsub!(/<p>&nbsp;<\/p>/, "\n\n")
    s.gsub!(/&#39;/, "'")
    s.gsub!(/\[url="(.+?)"\]http.+?\[\/url\]/, "\\1\n")
    s.gsub!(/\[media\](.+?)\[\/media\]/, "\n\\1\n\n")
    s.gsub!(/date=\'(.+?)\'/, '')
    s.gsub!(/timestamp=\'(.+?)\' /, '')

    # Convert code
    # I'm assuming the <C> also means code, and that it is a block of code.
    s.gsub!(/<C><s>.*?\<\/s>(.*?)<e>.*?<\/e><\/C>/im) { "\n```\n#{$1}\n```\n" }
    # Sometimes they use <CODE>
    s.gsub!(/<CODE><s>.*?\<\/s>(.*?)<e>.*?<\/e><\/CODE>/im) { "\n```\n#{$1}\n```\n" }

    # [URL=...]...[/URL]
    s.gsub!(/<URL.*?>(.*?)<\/URL>/m) { |m| $1.gsub(/<s>|<e>|<\/s>|<\/e>/, '') }

    # Lists
    s.gsub!(/<LIST.*?>(.+?)<\/LIST>/m) { |m| "\n" + $1.gsub(/<LI><s>(.*?)<\/s>(.*?)<\/LI>/) {"\n#{$1}#{$2} "} + "\n\n" }

    #Images
    s.gsub!(/(<IMG.*?>).*?(<\/IMG>)/m) { |m| "\n#{$1}#{$2}\n" }

    # [YOUTUBE]<id>[/YOUTUBE]
    s.gsub!(/\[youtube\](.+?)\[\/youtube\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [youtube=425,350]id[/youtube]
    s.gsub!(/\[youtube="?(.+?)"?\](.+)\[\/youtube\]/i) { "\nhttps://www.youtube.com/watch?v=#{$2}\n" }

    # [MEDIA=youtube]id[/MEDIA]
    s.gsub!(/\[MEDIA=youtube\](.+?)\[\/MEDIA\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [ame="youtube_link"]title[/ame]
    s.gsub!(/\[ame="?(.+?)"?\](.+)\[\/ame\]/i) { "\n#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    s.gsub!(/\[video=youtube;([^\]]+)\].*?\[\/video\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    #Emojis
    s.gsub!(/\{(\:\S*?\:)\}/, '\1')

    # Quotes
    s.gsub!(/<QUOTE>(.*?)<\/QUOTE>/im) do
      lines = $1
      lines.gsub!(/<i>&gt; <\/i>/, '')
      lines.gsub!(/<s>\[quote\]<\/s>/, '')
      lines.gsub!(/<e>\[\/quote\]<\/e>/, '')
      lines.gsub!(/(\n)*^/im, "\n>")
    end

    # Quote symbol: >
    s.gsub!(/<i>&gt; <\/i>/, '')

    # Mentions
    s.gsub!(/<POSTMENTION discussionid=\"(\w*)\" displayname=\"(\w*)\" id=\"(\w*)\" number=\"(\w*)\" username=\"(\w*)\">.*?<\/POSTMENTION>/i) do
      username = $5
      "@#{username}"
    end

    s
  end

  def create_permalinks
    puts '', 'Creating redirects...', ''

    Topic.find_each do |topic|
    pcf = topic.first_post.custom_fields
      if pcf && pcf["import_id"]
        id = pcf["import_id"]
        slug = Slug.for(topic.title)
        Permalink.create(url: "d/#{id}-#{slug}.html", topic_id: topic.id) rescue nil
        print '.'
      end
    end

  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::FLARUM.new.perform
