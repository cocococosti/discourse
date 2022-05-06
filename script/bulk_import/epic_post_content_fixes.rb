require 'mysql2'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")
require 'htmlentities'
require 'ruby-bbcode-to-md'

class ImportScripts::EpicFixes < BulkImport::Base

  DB_PREFIX = ""
  SUSPENDED_TILL ||= Date.new(3000, 1, 1)
  ATTACH_DIR ||= ENV['ATTACH_DIR'] || '/shared/import/data/attachments'
  AVATAR_DIR ||= ENV['AVATAR_DIR'] || '/shared/import/data/customavatars'
  ROOT_NODE = 2
  DRY_RUN = true

  def initialize
    super

    host     = ENV["DB_HOST"] || "localhost"
    username = ENV["DB_USERNAME"] || "root"
    password = ENV["DB_PASSWORD"] || "root"
    database = ENV["DB_NAME"] || "vb_web_pd04"
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
    refresh_post_raw
  end

  def check_database_for_attachment(row)
    # check if attachment resides in the database & try to retrieve
    if row[2].to_i == 0
      puts "Attachment file #{row.inspect} doesn't exist"
      return nil
    end

    tmpfile = 'attach_' + row[4].to_s
    filename = File.join('/tmp/', tmpfile)
    File.open(filename, 'wb') { |f| f.write(row[3]) }
    filename
  end

  def find_upload(post, opts = {})
    if opts[:attachment_id].present?
      sql = "SELECT a.filename, fd.userid, LENGTH(fd.filedata), filedata, fd.filedataid
               FROM #{DB_PREFIX}attach a
               LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
               LEFT JOIN #{DB_PREFIX}node n ON n.nodeid = a.nodeid
              WHERE a.nodeid = #{opts[:attachment_id]}"
    elsif opts[:filedata_id].present?
      sql = "SELECT a.filename, fd.userid, LENGTH(fd.filedata), filedata, fd.filedataid
               FROM #{DB_PREFIX}attachment a
               LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
              WHERE a.attachmentid = #{opts[:filedata_id]}"
    end

    results = mysql_query(sql)

    unless row = results.first
      puts "Couldn't find attachment record -- nodeid/filedataid = #{opts[:attachment_id] || opts[:filedata_id]} / post.id = #{post.id}"
      return nil
    end

    attachment_id = row[4]
    user_id = row[1]
    db_filename = row[0]

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

    [upload, real_filename]
  rescue Mysql2::Error => e
    puts "SQL Error"
    puts e.message
    puts sql
  end

  def import_attachments post_id
    puts '', 'importing attachments...'

    RateLimiter.disable

    # we need to match an older and newer style for inline attachment import
    # new style matches the nodeid in the attach table
    # old style matches the filedataid in attach/filedata tables
    attachment_regex = /\[attach[^\]]*\].*\"data-attachmentid\":"?(\d+)"?,?.*\[\/attach\]/i
    attachment_regex_oldstyle = /\[attach[^\]]*\](\d+)\[\/attach\]/i
    attachment_regex_url = /https?:\/\/forums.unrealengine.com\/filedata\/fetch\?id=(\d+)/i
    attachment_regex_url = /https?:\/\/forums.unrealengine.com\/attachment\.php\?attachmentid=(\d+)/i

    post = Post.find(post_id)

    new_raw = post.raw.dup

    # look for new style attachments
    new_raw.gsub!(attachment_regex) do |s|
      matches = attachment_regex.match(s)
      attachment_id = matches[1]

      upload, filename = find_upload(post, { attachment_id: attachment_id })

      unless upload
        puts "Attachments import for #{post_id} failed"
        next
      end

      html_for_upload(upload, filename)
    end

    # look for old style attachments
    new_raw.gsub!(attachment_regex_oldstyle) do |s|
      matches = attachment_regex_oldstyle.match(s)
      filedata_id = matches[1]

      upload, filename = find_upload(post, { filedata_id: filedata_id })

      unless upload
        puts "Attachments import for #{post_id} failed"
        next
      end

      html_for_upload(upload, filename)
    end

    # look for URL style attachments
    new_raw.gsub!(attachment_regex_url) do |s|
      matches = attachment_regex_url.match(s)
      attachment_id = matches[1]

      upload, filename = find_upload(post, { attachment_id: attachment_id })

      unless upload
        puts "Attachments import for #{post_id} failed"
        next
      end

      html_for_upload(upload, filename)
    end

    if new_raw != post.raw
      if DRY_RUN
        puts "The new raw (with attachments) is (DRY_RUN):"
        puts new_raw
      else
        puts "The new raw (with attachments) is:"
        puts new_raw
        PostRevisor.new(post).revise!(post.user, { raw: new_raw }, bypass_bump: true, edit_reason: 'Post content fix: Import attachments')
      end
    end

    puts "Attachements import successful for #{post_id}"
    RateLimiter.enable
  end

  def refresh_post_raw
    puts "Fixing posts content..."
    skipped = 0
    updated = 0
    total = 0
    
    broken = Post.where("cooked like '%[LIST]%' or cooked like '%[LIST=1]%' or cooked like '%[/LIST]%' or cooked like '%[list]%' or cooked like '%[list=1]%' or cooked like '%[/list]%' or cooked like '%[/ol]%' or cooked like '%[/li]%' or cooked like '%[/ul]%' or cooked like '%[ol]%' or cooked like '%[li]%' or cooked like '%[ul]%'")

    broken.each do |post|
      total += 1

      # Check if the post was updated after the migration
      migration_end_date = "2021-05-15"
      if post.updated_at > migration_end_date.to_date
        puts "Post #{post.id} has been update since the migration ended. Skipping."
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
        skipped += 1
        next
      end

      # Process raw text
      new_raw = process_raw(original_raw[0])

      # Update post
      if DRY_RUN
        puts "Updated (dry-run) post: #{post.id}"
        puts new_raw
        import_attachments post.id
        puts "--------------"
        updated += 1
      else
        PostRevisor.new(post).revise!(Discourse.system_user, { raw: new_raw }, bypass_bump: true, edit_reason: "Refresh post raw to fix parsing issues")
        import_attachments post.id
        puts "Updated post: #{post.id}"
        puts new_raw
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

    # convert list tags to ul and list=1 tags to ol
    # (basically, we're only missing list=a here...)
    # (https://meta.discourse.org/t/phpbb-3-importer-old/17397)
    # raw.gsub!(/\[list\](.*?)\[\/list\]/i, '[ul]\1[/ul]')
    # raw.gsub!(/\[list=1\|?[^\]]*\](.*?)\[\/list\]/i, '[ol]\1[/ol]')
    # raw.gsub!(/\[list\](.*?)\[\/list:u\]/i, '[ul]\1[/ul]')
    # raw.gsub!(/\[list=1\|?[^\]]*\](.*?)\[\/list:o\]/i, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    # raw.gsub!(/\[\*\]\n/, '')
    # raw.gsub!(/\[\*\](.*?)\[\/\*:m\]/, "<li>\n\n#{$1}\n\n</li>")
    # raw.gsub!(/\[\*\](.*?)\n/, "<li>\n\n#{$1}\n\n<li>")
    # raw.gsub!(/\[\*=1\]/, '')
    # raw.gsub!(/\[\*\]\n/, '')
    # raw.gsub!(/\[\*\](.*?)\[\/\*:m\]/, '<li>\1</li>')
    # raw.gsub!(/\[\*\](.*?)\n/, '<li>\1</li>')
    # raw.gsub!(/\[\*=1\]/, '')

    # Nested lists
    
    raw.gsub!(/\[\*\]\n/, '')
    raw.gsub!(/\[\*\](.*?)\[\/\*:m\]/i) do
      "<li>\n\n#{$1}\n\n</li>"
    end
    raw.gsub!(/\[\*\](((?!\[\*\]$|\[list\]$|\[\/list\]$).*))/i) do
      "<li>\n\n#{$2}\n\n</li>"
    end
    raw.gsub!(/\[\*=1\]/, '')

    raw.gsub!(/\[list\]/i, "\n\n<ul>\n\n")
    raw.gsub!(/\[list=1\|?[^\]]*\]/i, "\n\n<ul>\n\n")
    raw.gsub!(/\[\/list\]/i, "\n\n</ul>\n\n")
    raw.gsub!(/\[\/list:u\]/i, "\n\n</ul>\n\n")
    raw.gsub!(/\[\/list:o\]/i, "\n\n</ul>\n\n")

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
