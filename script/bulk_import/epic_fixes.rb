require 'mysql2'
require 'json'
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
    import_attachments

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

    puts "PATH: #{filename}"

    [upload, real_filename]
  rescue Mysql2::Error => e
    puts "SQL Error"
    puts e.message
    puts sql
  end

  def is_missing(raw, missing_uploads_counter, uploads_counter, uploads)
    # Check the upload we are processing form the original post is actually the upload that is missing
    # in the imported post (in case of posts with multiple images)
    regex = /(\(upload:\/\/[^)]+\))/i
    counter = 0
    missing = false
    text = raw.dup

    text.gsub!(regex) do |s|
      puts "THE COUNTER IS #{counter}"
      puts "THE UPLOADS_COUNTER IS #{uploads_counter}"
      puts "THE MISSING_UPLOADS COUNTER IS #{missing_uploads_counter}"
      matches = regex.match(s)
      upload = matches[1]
      puts "THE UPLOAD IS #{upload}"
      if "("+uploads[missing_uploads_counter]+")" == upload
        puts "Upload matches: original is #{upload} and the reported mising is #{uploads[uploads_counter]}"
        missing = true
      end
      counter += 1
    end

    return missing
  end

  def import_attachments

    puts "Checking for missing uploads..."

    fail_count = 0
    success_count = 0
    skipped = 0

    # Generated from the missing uploads rake task
    missing_uploads = PostCustomField.where(name: Post::MISSING_UPLOADS)

    missing_uploads.each do |missing_upload|
      puts "#################################################################################"

      post_id = missing_upload.post_id
      uploads = JSON.parse missing_upload.value
      import_id = PostCustomField.where(name: 'import_id', post_id: post_id)

      if import_id.nil? || import_id.empty?
        fail_count += 1
        puts "Import ID not found for #{post_id}"
        next
      end

      import_id = import_id.first.value

      post = Post.find(post_id)

      puts "The post with the missing upload(s) is: #{post_id}"
      puts "The topic is #{post.topic_id}"
      puts "The missing uploads are: #{uploads}"
      puts "The original post is: #{import_id}"

      # Check if post has been edited since last migration
      migration_end_date = "2021-05-15"
      if post.updated_at > migration_end_date.to_date
        fail_count += 1
        puts "Post #{post_id} has been update since the migration ended. Skipping."
        skipped += 1
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
        puts "Original content not found for #{post_id}"
        next
      end

      original_content = original_content.first.to_s

      attachment_regex = /\[attach[^\]]*\].*[\\]*\"data-attachmentid[\\]*\":[\\]*"?(\d+)[\\]*"?,?.*\[\/attach\]/i
      attachment_regex_oldstyle = /\[attach[^\]]*\](\d+)\[\/attach\]/i

      # These counter are used to check which uploads in the post we're processing (in case of posts with multiple images)
      missing_uploads_counter = 0
      uploads_counter = -1

      # Look for new style attachments
      original_content.gsub!(attachment_regex) do |s|
        if missing_uploads_counter >= uploads.length
          puts "All missing uploads checked. Skipping the rest."
          break
        end

        uploads_counter += 1
        matches = attachment_regex.match(s)
        node_id = matches[1]

        # Not all images in the original post are missing in the migrated ones
        if is_missing(raw, missing_uploads_counter, uploads_counter, uploads)
          puts "The upload to substitute is #{uploads[missing_uploads_counter]}"
          
          upload, filename = find_upload(post, { node_id: node_id })

          puts "UPLOAD #{upload}"
          puts "FILENAME #{filename}"

          unless upload
            fail_count += 1
            missing_uploads_counter += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{node_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end
          
          puts "----------------------------------------------------------------------"
          html = html_for_upload(upload, filename)
          puts "The HTML to substitute is #{html}"
          new_raw.gsub! /!\[[^\]]+\]\(#{uploads[missing_uploads_counter]}\)/, html
          missing_uploads_counter += 1
        else
          puts "It's not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end

      end

      # Look for old style attachments
      original_content.gsub!(attachment_regex_oldstyle) do |s|
        if missing_uploads_counter >= uploads.length
          puts "All missing uploads checked. Skipping the rest."
          break
        end

        uploads_counter += 1
        matches = attachment_regex_oldstyle.match(s)
        attachment_id = matches[1]

        if is_missing(raw, missing_uploads_counter, uploads_counter, uploads)
          puts "The upload to substitute is #{uploads[missing_uploads_counter]}"

          upload, filename = find_upload(post, { attachment_id: attachment_id })

          puts "UPLOAD #{upload}"
          puts "FILENAME #{filename}"

          unless upload
            fail_count += 1
            missing_uploads_counter += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{attachment_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end

          puts "----------------------------------------------------------------------"
          html = html_for_upload(upload, filename)
          puts "The HTML to substitute is #{html}"
          new_raw.gsub! /!\[[^\]]+\]\(#{uploads[missing_uploads_counter]}\)/, html
          missing_uploads_counter += 1
        else
          puts "It's not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end
      end

      if new_raw != raw
        post['raw'] = new_raw
        post.save(validate: false)
        PostCustomField.create(post_id: post.id, name: "upload_fixed", value: true)
        success_count += 1
      end
    end

    puts "", "imported #{success_count} attachments... failed: #{fail_count}... skipped: #{skipped}"

  end

  def mysql_stream(sql)
    @client.query(sql, stream: true)
  end

  def mysql_query(sql)
    @client.query(sql)
  end
end

ImportScripts::EpicFixes.new.execute
