require 'mysql2'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")
require 'htmlentities'
require 'ruby-bbcode-to-md'

class ImportScripts::EpicFixes < BulkImport::Base

  DB_PREFIX = ""
  SUSPENDED_TILL ||= Date.new(3000, 1, 1)
  ATTACH_DIR ||= ENV['ATTACH_DIR'] || '/shared/import/data/import_uploads'
  ROOT_NODE = 2

  def initialize
    super

    host     = ENV["DB_HOST"] || "localhost"
    username = ENV["DB_USERNAME"] || "root"
    password = ENV["DB_PASSWORD"]
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
    # fix incorrect attachments
    # refresh_post_raw
    import_attachments

  end


  def refresh_post_raw
    post_with_attachments = mysql_query <<-SQL
      SELECT n.nodeid, rawtext
        FROM #{DB_PREFIX}node n
        LEFT JOIN #{DB_PREFIX}text txt ON txt.nodeid = n.nodeid
       WHERE rawtext LIKE '%[ATTACH%'
    SQL

    post_with_attachments.each do |post|
      imported_post = Post.find(post_id_from_imported_post_id(post[0]))

      # process raw text
      new_raw = post[1]
      new_raw = preprocess_raw(new_raw)

      # add a post revision
      PostRevisor.new(imported_post).revise!(Discourse.system_user, { raw: new_raw }, bypass_bump: true, edit_reason: "Refresh post raw for attachments")

      # reset attachment import field
      imported_post.custom_fields[:import_attachments] = false
      imported_post.save!
    end
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

  def import_attachments
    puts '', 'importing missing attachments...'

    total_count = 0

    PostCustomField.where(name: Post::MISSING_UPLOADS).pluck(:post_id, :value).each do |post_id, uploads|
      post = Post.where(id: post_id)
      raw = post.first.raw
      new_raw = raw.dup 

      original_post_id = PostCustomField.where(name: 'import_id', post_id: post_id).pluck(:value)

      upload = mysql_query <<-SQL
      SELECT n.parentid nodeid, a.filename, fd.userid, LENGTH(fd.filedata) AS dbsize, filedata, fd.filedataid
        FROM #{DB_PREFIX}attach a
        LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
        LEFT JOIN #{DB_PREFIX}node n on n.nodeid = a.nodeid
        WHERE n.parentid = #{original_post_id}
      SQL

      if upload.nil?
        puts "Upload for #{post.id} not found"
        next
      end

      filename = File.join(ATTACH_DIR, upload['userid'].to_s.split('').join('/'), "#{upload['filedataid']}.attach")
      real_filename = upload['filename']
      real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

      unless File.exists?(filename)
        # attachments can be on filesystem or in database
        # try to retrieve from database if the file did not exist on filesystem
        if upload['dbsize'].to_i == 0
          puts "Attachment file #{upload['filedataid']} doesn't exist"
          next
        end

        tmpfile = 'attach_' + upload['filedataid'].to_s
        filename = File.join('/tmp/', tmpfile)
        File.open(filename, 'wb') { |f|
          f.write(upload['filedata'])
        }
        return nil if filename.nil?
      end

      puts "POST ID: #{post_id}"
      puts "ORIGONAL POST ID: #{original_post_id}"
      puts "PATH IN FILESYSTEM: #{filename}"
      puts "FILENAME: #{real_filename}"
      puts "POST CONTENT: #{uploads}"

      # upl_obj = create_upload(post.user_id, filename, real_filename)

      # if upl_obj&.persisted?
      #   new_raw.gsub!(uploads) do |s|
      #     html_for_upload(upl_obj, filename)
      #   end
      # else
      #   puts "Fail"
      #   exit
      # end

      # if new_raw != post.raw
      #   post.raw = new_raw
      #   post.save(validate: false)
      # end

      total_count += 1
    end
    puts "Total uploads porcessed succesfully: #{total_count}"
  end

  def preprocess_raw(text)
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

    # [FONT=font]...[/FONT]
    raw.gsub!(/\[FONT=\w*\]/im, "")
    raw.gsub!(/\[\/FONT\]/im, "")

    # @[URL=<user_profile>]<username>[/URL]
    # [USER=id]username[/USER]
    # [MENTION=id]username[/MENTION]
    raw.gsub!(/@\[URL=\"\S+\"\]([\w\s]+)\[\/URL\]/i) { "@#{$1.gsub(" ", "_")}" }
    raw.gsub!(/\[USER=\"\d+\"\]([\S]+)\[\/USER\]/i) { "@#{$1.gsub(" ", "_")}" }
    raw.gsub!(/\[MENTION=\d+\]([\S]+)\[\/MENTION\]/i) { "@#{$1.gsub(" ", "_")}" }

    # [IMG2=JSON]{..."src":"<url>"}[/IMG2]
    raw.gsub!(/\[img2[^\]]*\].*\"src\":\"?([\w\\\/:\.\-;%]*)\"?}.*\[\/img2\]/i) { "\n#{CGI::unescape($1)}\n" }

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
    raw.gsub!(/\[list\](.*?)\[\/list\]/im, '[ul]\1[/ul]')
    raw.gsub!(/\[list=1\|?[^\]]*\](.*?)\[\/list\]/im, '[ol]\1[/ol]')
    raw.gsub!(/\[list\](.*?)\[\/list:u\]/im, '[ul]\1[/ul]')
    raw.gsub!(/\[list=1\|?[^\]]*\](.*?)\[\/list:o\]/im, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    raw.gsub!(/\[\*\]\n/, '')
    raw.gsub!(/\[\*\](.*?)\[\/\*:m\]/, '[li]\1[/li]')
    raw.gsub!(/\[\*\](.*?)\n/, '[li]\1[/li]')
    raw.gsub!(/\[\*=1\]/, '')

    raw
  end

  def mysql_stream(sql)
    @client.query(sql, stream: true)
  end

  def mysql_query(sql)
    @client.query(sql)
  end
end

ImportScripts::EpicFixes.new.execute
