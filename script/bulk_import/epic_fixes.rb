require 'mysql2'
require 'json'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")
require 'htmlentities'
require 'ruby-bbcode-to-md'

class ImportScripts::EpicFixes < BulkImport::Base

  DB_PREFIX = ""
  SUSPENDED_TILL ||= Date.new(3000, 1, 1)
  ATTACH_DIR ||= ENV['ATTACH_DIR'] || '/var/www/discourse/import_uploads/missing_images'
  ROOT_NODE = 2
  DRY_RUN = true

  def initialize
    super

    host     = ENV["DB_HOST"] || "172.17.0.8"
    username = ENV["DB_USERNAME"] || "root"
    password = ENV["DB_PASSWORD"] || "mypass"
    database = ENV["DB_NAME"] || "old_epic"
    charset  = ENV["DB_CHARSET"] || "utf8"

    @html_entities = HTMLEntities.new
    @encoding = CHARSET_MAP[charset]
    @bbcode_to_md = true

    @client = Mysql2::Client.new(
      host: host,
      username: username,
      password: password,
      database: database,
      encoding: charset,
      reconnect: true
    )

    @client.query_options.merge!(as: :array, cache_rows: false)

    @channel_typeid = mysql_query("SELECT contenttypeid FROM #{DB_PREFIX}contenttype WHERE class='Channel'").to_a[0][0]
    @post_typeids = "39,40,43,44,50" #Poll,Gallery,Video,Link,Event
  end

  def execute
    #import_attachments
    refresh_post_raw
  end

  def check_database_for_attachment(row)
    # check if attachment resides in the database & try to retrieve
    if row[4].to_i == 0
      puts "Attachment file #{row.inspect} doesn't exist"
      return nil
    end

    tmpfile = 'attach_' + row[6].to_s
    filename = File.join('/tmp/', tmpfile)
    File.open(filename, 'wb') { |f| f.write(row[5]) }
    filename
  end

  def find_upload(post, opts = {})
    if opts[:node_id].present?
      sql = "SELECT a.nodeid, n.parentid, a.filename, fd.userid, LENGTH(fd.filedata), filedata, fd.filedataid
               FROM #{DB_PREFIX}attach a
               LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
               LEFT JOIN #{DB_PREFIX}node n ON n.nodeid = a.nodeid
              WHERE a.nodeid = #{opts[:node_id]}"
    elsif opts[:attachment_id].present?
      sql = "SELECT '', '', a.filename, fd.userid, LENGTH(fd.filedata), filedata, fd.filedataid
               FROM #{DB_PREFIX}attachment a
               LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
              WHERE a.attachmentid = #{opts[:attachment_id]}"
    end

    results = mysql_query(sql)

    unless row = results.first
      puts "Couldn't find attachment record -- nodeid/filedataid = #{opts[:attachment_id] || opts[:filedata_id]} / post.id = #{post.id}"
      return nil
    end

    attachment_id = row[6]
    user_id = row[3]
    db_filename = row[2]

    filename = File.join(ATTACH_DIR, user_id.to_s.split('').join('/'), "#{attachment_id}.attach")
    real_filename = db_filename
    real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

    unless File.exists?(filename)
      filename = check_database_for_attachment(row) if filename.blank?
      return nil if filename.nil?
    end

    upload = create_upload(post.user_id, filename, real_filename)

    if upload.nil? || !upload.valid?
      puts "Upload not valid"
      puts upload.errors.inspect if upload
      return
    end

    #puts "PATH: #{filename}"

    [upload, real_filename]
  rescue Mysql2::Error => e
    puts "SQL Error"
    puts e.message
    puts sql
  end

  def is_missing(raw, missing_uploads_counter, uploads)
    # check the upload we are processing form the original post is actually the upload that is missing
    # in the imported post (in case of posts with multiple images)
    regex = /(\(upload:\/\/[^)]+\))/i
    missing = false
    text = raw.dup

    text.gsub!(regex) do |s|
      matches = regex.match(s)
      upload = matches[1]
      if "("+uploads[missing_uploads_counter]+")" == upload
        #puts "Upload matches: original is #{upload} and the reported mising is #{uploads[uploads_counter]}"
        missing = true
        return missing
      end
    end

    return missing
  end

  def import_attachments
    puts "Checking for missing uploads..."

    fail_count = 0
    success_count = 0

    # Generated from the missing uploads rake task
    missing_uploads = PostCustomField.where(name: Post::MISSING_UPLOADS)

    missing_uploads.each do |missing_upload|
      post_id = missing_upload.post_id

      puts "#################################################################################"
      puts "Processing missing uploads for post #{post_id}..."

      uploads = JSON.parse missing_upload.value
      import_id = PostCustomField.where(name: 'import_id', post_id: post_id)

      missing_uploads_counter = 0
      uploads_counter = -1

      if import_id.nil? || import_id.empty?
        fail_count += 1
        puts "Import ID not found for post #{post_id}. Skipping."
        next
      end

      import_id = import_id.first.value

      post = Post.where(id: post_id).first

      # Check if post has been edited since last migration
      migration_end_date = "2021-05-15"
      if post.updated_at > migration_end_date.to_date
        fail_count += 1
        puts "Post #{post_id} has been updated since the migration ended. Skipping."
        next
      end

      raw = post['raw']
      new_raw = raw.dup

      original_content = mysql_query <<-SQL
        SELECT rawtext from #{DB_PREFIX}text txt
        WHERE txt.nodeid = #{import_id}
      SQL

      if original_content.first.nil?
        fail_count += 1
        puts "Original content not found for post #{post_id}. Skipping."
        next
      end

      original_content = original_content.first.to_s

      attachment_regex = /\[attach[^\]]*\].*[\\]*\"data-attachmentid[\\]*\":[\\]*"?(\d+)[\\]*"?,?.*\[\/attach\]/i
      attachment_regex_oldstyle = /\[attach[^\]]*\](\d+)\[\/attach\]/i

      # look for new style attachments
      original_content.gsub!(attachment_regex) do |s|
        if missing_uploads_counter >= uploads.length
          puts "All missing uploads checked for post #{post_id}. Skipping the rest."
          break
        end

        uploads_counter += 1
        matches = attachment_regex.match(s)
        node_id = matches[1]

        # not all images in the original post are missing in the migrated ones
        if is_missing(raw, missing_uploads_counter, uploads)
          #puts "The upload to substitute is #{uploads[missing_uploads_counter]}"

          missing_uploads_counter += 1
          upload, filename = find_upload(post, { node_id: node_id })

          unless upload
            fail_count += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{node_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end
          
          html = html_for_upload(upload, filename)
          new_raw.gsub! /!\[[^\]]+\]\(#{uploads[missing_uploads_counter]}\)/, html
          success_count += 1
          puts "Upload: #{s} found for post #{post_id}"
          puts "----------------------------------------------------------------------"
        else
          puts "Upload: #{s} is not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end
      end

      # look for old style attachments
      original_content.gsub!(attachment_regex_oldstyle) do |s|
        if missing_uploads_counter >= uploads.length
          puts "All missing uploads checked for post #{post_id}. Skipping the rest."
          break
        end

        uploads_counter += 1
        matches = attachment_regex_oldstyle.match(s)
        attachment_id = matches[1]

        # not all images in the original post are missing in the migrated ones
        if is_missing(raw, missing_uploads_counter, uploads)
          #puts "The upload to substitute is #{uploads[missing_uploads_counter]}"

          missing_uploads_counter += 1
          upload, filename = find_upload(post, { attachment_id: attachment_id })

          unless upload
            fail_count += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{attachment_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end
          
          html = html_for_upload(upload, filename)
          new_raw.gsub! /!\[[^\]]+\]\(#{uploads[missing_uploads_counter]}\)/, html
          success_count += 1
          puts "Upload: #{s} found for post #{post_id}"
          puts "----------------------------------------------------------------------"
        else
          puts "Upload: #{s} is not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end
      end

      if new_raw != raw
        post['raw'] = new_raw
        post.save(validate: false)
        PostCustomField.create(post_id: post.id, name: "upload_fixed", value: true)
        puts "Uploads updated successfully for post #{post_id}."
      end
    end

    puts "", "imported #{success_count} attachments... failed: #{fail_count}"
  end

  def refresh_post_raw
    puts "Fixing posts content..."
    skipped = 0
    updated = 0
    total = 0
    
    broken = Post.where("lower(cooked) like '%[list]%' or lower(cooked) like '%[list=1]%' or lower(cooked) like '%[/list]%' or lower(cooked) like '%[/ol]%' or lower(cooked) like '%[/li]%' or lower(cooked) like '%[/ul]%' or lower(cooked) like '%[ol]%' or lower(cooked) like '%[li]%' or lower(cooked) like '%[ul]%'")

    broken.each do |post|
      total += 1

      # Check if the post was updated after the migration
      migration_end_date = "2021-05-15"
      if post.updated_at > migration_end_date.to_date
        puts "Post #{post.id} has been update since the migration ended. Skipping."
        puts "--------------"
        skipped += 1
        next
      end

      import_id = PostCustomField.where(name: 'import_id', post_id: post.id).first.value

      original_raw = mysql_query <<-SQL
      SELECT rawtext
        FROM text
        WHERE nodeid = #{import_id.to_i}
      SQL

      original_raw = original_raw.first

      if original_raw.nil?
        puts "Original content not found for post #{post.id}. Skipping."
        puts "--------------"
        skipped += 1
        next
      end

      # Process raw text
      new_raw = process_raw(original_raw[0])

      # Update post
      if DRY_RUN
        puts "Updated (dry-run) post: #{post.id}"
        puts new_raw
        puts "--------------"
        updated += 1
      else
        PostRevisor.new(post).revise!(Discourse.system_user, { raw: new_raw }, bypass_bump: true, edit_reason: "Refresh post raw to fix parsing issues")
        PostCustomField.create(post_id: post.id, name: "list_format_fixed", value: true)
        puts "Updated post: #{post.id}"
        puts "--------------"
        updated += 1
      end
    end

    puts "Posts updated: #{updated}"
    puts "Posts skipped: #{skipped}"
    puts "Total: #{total}"
  end

  def process_raw(text)
    return "" if text.nil?
    raw = text.dup
    raw = normalize_text(raw)
    raw = process_bbcode(raw)

    raw = raw.bbcode_to_md(false, {}, :enable, :ul, :ol, :li) rescue raw

    raw
  end

  def normalize_text(text)
    return nil unless text.present?
    @html_entities.decode(normalize_charset(text.presence || "").scrub)
  end

  CHARSET_MAP = {
    "armscii8" => nil,
    "ascii"    => Encoding::US_ASCII,
    "big5"     => Encoding::Big5,
    "binary"   => Encoding::ASCII_8BIT,
    "cp1250"   => Encoding::Windows_1250,
    "cp1251"   => Encoding::Windows_1251,
    "cp1256"   => Encoding::Windows_1256,
    "cp1257"   => Encoding::Windows_1257,
    "cp850"    => Encoding::CP850,
    "cp852"    => Encoding::CP852,
    "cp866"    => Encoding::IBM866,
    "cp932"    => Encoding::Windows_31J,
    "dec8"     => nil,
    "eucjpms"  => Encoding::EucJP_ms,
    "euckr"    => Encoding::EUC_KR,
    "gb2312"   => Encoding::EUC_CN,
    "gbk"      => Encoding::GBK,
    "geostd8"  => nil,
    "greek"    => Encoding::ISO_8859_7,
    "hebrew"   => Encoding::ISO_8859_8,
    "hp8"      => nil,
    "keybcs2"  => nil,
    "koi8r"    => Encoding::KOI8_R,
    "koi8u"    => Encoding::KOI8_U,
    "latin1"   => Encoding::ISO_8859_1,
    "latin2"   => Encoding::ISO_8859_2,
    "latin5"   => Encoding::ISO_8859_9,
    "latin7"   => Encoding::ISO_8859_13,
    "macce"    => Encoding::MacCentEuro,
    "macroman" => Encoding::MacRoman,
    "sjis"     => Encoding::SHIFT_JIS,
    "swe7"     => nil,
    "tis620"   => Encoding::TIS_620,
    "ucs2"     => Encoding::UTF_16BE,
    "ujis"     => Encoding::EucJP_ms,
    "utf8"     => Encoding::UTF_8,
  }

  def normalize_charset(text)
    return text if @encoding == Encoding::UTF_8
    text && text.encode(@encoding).force_encoding(Encoding::UTF_8)
  end

  def process_bbcode(raw)
    # [PLAINTEXT]...[/PLAINTEXT]
    raw.gsub!(/\[\/?PLAINTEXT\]/i, "\n\n```\n\n")

    # [FONT="courier new"]...[/FONT]
    # Code inline
    raw.gsub!(/\[FONT=courier new\](.*)\[\/FONT\]/i) { "`#{$1}`" }
    # Code block
    raw.gsub!(/\[FONT=courier new\]((.*)(\n)*(.*)(\n)*)\[\/FONT\]/im) { "\n```\n#{$1}\n```\n" }

    # [FONT=font]...[/FONT]
    raw.gsub!(/\[FONT=\w*\]/i, "")
    raw.gsub!(/\[\/FONT\]/i, "")

    # Bold
    raw.gsub!(/\*\*( )+(.*)( )+\*\*/im) { "**#{$2}**" }
    raw.gsub!(/\*\*(.*)( )+\*\*/im) { "**#{$1}**" }
    raw.gsub!(/\*\*( )+(.*)\*\*/im) { "**#{$2}**" }

    # @[URL=<user_profile>]<username>[/URL]
    # [USER=id]username[/USER]
    # [MENTION=id]username[/MENTION]
    raw.gsub!(/@\[URL=\"\S+\"\]([\w\s]+)\[\/URL\]/i) { "@#{$1.gsub(" ", "_")}" }
    raw.gsub!(/\[USER=\"\d+\"\]([\S]+)\[\/USER\]/i) { "@#{$1.gsub(" ", "_")}" }
    raw.gsub!(/\[MENTION=\d+\]([\S]+)\[\/MENTION\]/i) { "@#{$1.gsub(" ", "_")}" }

    # [IMG2=JSON]{..."src":"<url>"}[/IMG2]
    raw.gsub!(/\[img2[^\]]*\]{.*(\\)*\"src(\\)*\":(\\)*\"?([\w\\\/:\.\-;%\?\=\&]*)(\\)*\"?}.*\[\/img2\]/i) do
      "\n#{CGI::unescape($4)}\n"
    end

    # [TABLE]...[/TABLE]
    raw.gsub!(/\[TABLE=\\"[\w:\-\s,]+\\"\]/i, "")
    raw.gsub!(/\[\/TABLE\]/i, "")

    # [HR]...[/HR]
    raw.gsub(/\[HR\]\s*\[\/HR\]/im, "---")

    # [VIDEO=youtube_share;<id>]...[/VIDEO]
    # [VIDEO=vimeo;<id>]...[/VIDEO]
    raw.gsub!(/\[VIDEO=YOUTUBE_SHARE;([^\]]+)\].*?\[\/VIDEO\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }
    raw.gsub!(/\[VIDEO=VIMEO;([^\]]+)\].*?\[\/VIDEO\]/i) { "\nhttps://vimeo.com/#{$1}\n" }

    # fix whitespaces
    raw.gsub!(/(\\r)?\\n/, "\n")
    raw.gsub!("\\t", "\t")

    # [HTML]...[/HTML]
    raw.gsub!(/\[HTML\]/i, "\n\n```html\n")
    raw.gsub!(/\[\/HTML\]/i, "\n```\n\n")

    # [PHP]...[/PHP]
    raw.gsub!(/\[PHP\]/i, "\n\n```php\n")
    raw.gsub!(/\[\/PHP\]/i, "\n```\n\n")

    # [HIGHLIGHT="..."]
    raw.gsub!(/\[HIGHLIGHT="?(\w+)"?\]/i) { "\n\n```#{$1.downcase}\n" }

    # [CODE]...[/CODE]
    # [HIGHLIGHT]...[/HIGHLIGHT]
    raw.gsub!(/\[\/?CODE\]/i, "\n\n```\n\n")
    raw.gsub!(/\[\/?HIGHLIGHT\]/i, "\n\n```\n\n")

    # [SAMP]...[/SAMP]
    raw.gsub!(/\[\/?SAMP\]/i, "`")

    # replace all chevrons with HTML entities
    # /!\ must be done /!\
    #  - AFTER the "code" processing
    #  - BEFORE the "quote" processing
    raw.gsub!(/`([^`]+?)`/im) { "`" + $1.gsub("<", "\u2603") + "`" }
    raw.gsub!("<", "&lt;")
    raw.gsub!("\u2603", "<")

    raw.gsub!(/`([^`]+?)`/im) { "`" + $1.gsub(">", "\u2603") + "`" }
    raw.gsub!(">", "&gt;")
    raw.gsub!("\u2603", ">")

    raw.gsub!(/\[\/?I\]/i, "*")
    raw.gsub!(/\[\/?B\]/i, "**")
    raw.gsub!(/\[\/?U\]/i, "")

    raw.gsub!(/\[\/?RED\]/i, "")
    raw.gsub!(/\[\/?BLUE\]/i, "")

    raw.gsub!(/\[AUTEUR\].+?\[\/AUTEUR\]/im, "")
    raw.gsub!(/\[VOIRMSG\].+?\[\/VOIRMSG\]/im, "")
    raw.gsub!(/\[PSEUDOID\].+?\[\/PSEUDOID\]/im, "")

    # [IMG]...[/IMG]
    raw.gsub!(/(?:\s*\[IMG\]\s*)+(.+?)(?:\s*\[\/IMG\]\s*)+/im) { "\n\n#{$1}\n\n" }

    # [IMG=url]
    raw.gsub!(/\[IMG=([^\]]*)\]/im) { "\n\n#{$1}\n\n" }

    # [URL=...]...[/URL]
    raw.gsub!(/\[URL="?(.+?)"?\](.+?)\[\/URL\]/im) { "[#{$2.strip}](#{$1})" }

    # [URL]...[/URL]
    # [MP3]...[/MP3]
    # [EMAIL]...[/EMAIL]
    # [LEFT]...[/LEFT]
    raw.gsub!(/\[\/?URL\]/i, "")
    raw.gsub!(/\[\/?MP3\]/i, "")
    raw.gsub!(/\[\/?EMAIL\]/i, "")
    raw.gsub!(/\[\/?LEFT\]/i, "")

    # [FONT=blah] and [COLOR=blah]
    raw.gsub!(/\[FONT=.*?\](.*?)\[\/FONT\]/im, "\\1")
    raw.gsub!(/\[COLOR=.*?\](.*?)\[\/COLOR\]/im, "\\1")

    raw.gsub!(/\[SIZE=.*?\](.*?)\[\/SIZE\]/im, "\\1")
    raw.gsub!(/\[H=.*?\](.*?)\[\/H\]/im, "\\1")

    # [CENTER]...[/CENTER]
    raw.gsub!(/\[CENTER\](.*?)\[\/CENTER\]/im, "\\1")

    # [INDENT]...[/INDENT]
    raw.gsub!(/\[INDENT\](.*?)\[\/INDENT\]/im, "\\1")
    raw.gsub!(/\[TABLE\](.*?)\[\/TABLE\]/im, "\\1")
    raw.gsub!(/\[TR\](.*?)\[\/TR\]/im, "\\1")
    raw.gsub!(/\[TD\](.*?)\[\/TD\]/im, "\\1")
    raw.gsub!(/\[TD="?.*?"?\](.*?)\[\/TD\]/im, "\\1")

    # [STRIKE]
    raw.gsub!(/\[strike\]/i, "<s>")
    raw.gsub!(/\[\/strike\]/i, "</s>")

    # [QUOTE]...[/QUOTE]
    raw.gsub!(/\[QUOTE="([^\]]+)"\]/i) { "[QUOTE=#{$1}]" }

    # Nested Quotes
    raw.gsub!(/(\[\/?QUOTE.*?\])/mi) { |q| "\n#{q}\n" }

    # raw.gsub!(/\[QUOTE\](.+?)\[\/QUOTE\]/im) { |quote|
    #   quote.gsub!(/\[QUOTE\](.+?)\[\/QUOTE\]/im) { "\n#{$1}\n" }
    #   quote.gsub!(/\n(.+?)/) { "\n> #{$1}" }
    # }

    # [QUOTE=<username>;<postid>]
    raw.gsub!(/\[QUOTE=([^;\]]+);n(\d+)\]/i) do
      imported_username, imported_postid = $1, $2
      puts imported_username

      puts imported_postid

      username = imported_username
      post_number = post_number_from_imported_id(imported_postid)
      topic_id = topic_id_from_imported_post_id(imported_postid)

      if post_number && topic_id
        "\n[quote=\"#{username}, post:#{post_number}, topic:#{topic_id}\"]\n"
      else
        "\n[quote=\"#{username}\"]\n"
      end
    end

    # [YOUTUBE]<id>[/YOUTUBE]
    raw.gsub!(/\[YOUTUBE\](.+?)\[\/YOUTUBE\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }
    raw.gsub!(/\[DAILYMOTION\](.+?)\[\/DAILYMOTION\]/i) { "\nhttps://www.dailymotion.com/video/#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    raw.gsub!(/\[VIDEO=YOUTUBE;([^\]]+)\].*?\[\/VIDEO\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }
    raw.gsub!(/\[VIDEO=YOUTUBE;([^\]]+)\].*?\[\/VIDEO\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }
    raw.gsub!(/\[VIDEO=DAILYMOTION;([^\]]+)\].*?\[\/VIDEO\]/i) { "\nhttps://www.dailymotion.com/video/#{$1}\n" }

    # [SPOILER=Some hidden stuff]SPOILER HERE!![/SPOILER]
    raw.gsub!(/\[SPOILER="?(.+?)"?\](.+?)\[\/SPOILER\]/im) { "\n#{$1}\n[spoiler]#{$2}[/spoiler]\n" }

    # Nested lists
    raw.gsub!(/\[\*\]\n/, '')
    raw.gsub!(/\[\*\](\[\*\])*(.*?)\[\/\*:m\]/i) do
      "<li>\n\n#{$2}\n\n</li>"
    end
    raw.gsub!(/\[\*\](\[\*\])*(((?!\[\*\]$|\[list\]$|\[\/list\]$).*))/i) do
      "<li>\n\n#{$3}\n\n</li>"
    end
    raw.gsub!(/\[\*=1\]/, '')

    raw.gsub!(/(\[\*\])*\[list\]/i, "\n\n<ul>\n\n")
    raw.gsub!(/(\[\*\])*\[list=1\|?[^\]]*\]/i, "\n\n<ul>\n\n")
    raw.gsub!(/(\[\*\])*\[\/list\]/i, "\n\n</ul>\n\n")
    raw.gsub!(/(\[\*\])*\[\/list:u\]/i, "\n\n</ul>\n\n")
    raw.gsub!(/(\[\*\])*\[\/list:o\]/i, "\n\n</ul>\n\n")

    raw
  end

  def mysql_stream(sql)
    @client.query(sql, stream: true)
  end

  def mysql_query(sql)
    @client.query(sql)
  end
end

ImportScripts::EpicFixes.new.run
