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
    #import_attachments
    #import_attachments_two
    import_attachments_three

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

    #upload = create_upload(post.user_id, filename, real_filename)
    upload = {}

    if upload.nil? #|| !upload.valid?
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
    # check the upload we are processing form the original post is actually the upload that is missing
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

  def import_attachments_three

    puts "Checking for missing uploads..."

    fail_count = 0
    success_count = 0

    # Generated from the missing uploads rake task
    missing_uploads = PostCustomField.where(name: Post::MISSING_UPLOADS)

    missing_uploads.each do |missing_upload|
      puts "#################################################################################"

      post_id = missing_upload.post_id
      uploads = JSON.parse missing_upload.value
      import_id = PostCustomField.where(name: 'import_id', post_id: post_id)

      missing_uploads_counter = 0
      uploads_counter = -1

      if import_id.nil? || import_id.empty?
        fail_count += 1
        puts "Import ID not found for #{post_id}"
        next
      end

      import_id = import_id.first.value

      post = Post.where(id: post_id).first

      puts "The post with the missing upload(s) is: #{post_id}"
      puts "The topic is #{post.topic_id}"
      puts "The missing uploads are: #{uploads}"
      puts "The original post is: #{import_id}"

      # Check if post has been edited since last migration
      migration_end_date = "2021-05-15"
      if post.updated_at > migration_end_date.to_date
        fail_count += 1
        puts "Post #{post_id} has been update since the migration ended"
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
        puts "Original content not found"
        next
      end

      original_content = original_content.first.to_s

      puts "THE ORIGINAL CONTENT IS #{original_content}"

      attachment_regex = /\[attach[^\]]*\].*[\\]*\"data-attachmentid[\\]*\":[\\]*"?(\d+)[\\]*"?,?.*\[\/attach\]/i
      attachment_regex_oldstyle = /\[attach[^\]]*\](\d+)\[\/attach\]/i

      # look for new style attachments
      original_content.gsub!(attachment_regex) do |s|
        if missing_uploads_counter >= uploads.length
          puts "All missing uploads checked. Skipping the rest."
          break
        end

        uploads_counter += 1
        matches = attachment_regex.match(s)
        node_id = matches[1]

        # not all images in the original post are missing in the migrated ones
        if is_missing(raw, missing_uploads_counter, uploads_counter, uploads)
          puts "The upload to substitute is #{uploads[missing_uploads_counter]}"
          missing_uploads_counter += 1
          
          upload, filename = find_upload(post, { node_id: node_id })

          puts "UPLOAD #{upload}"
          puts "FILENAME #{filename}"

          unless upload
            fail_count += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{node_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end
          
          puts "----------------------------------------------------------------------"
          # html = html_for_upload(upload, filename)
          # puts "The HTML to substitute is #{html}"
          # new_raw[uploads[missing_uploads_counter]] = html
          success_count += 1
        else
          puts "It's not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end

      end

      # look for old style attachments
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
          missing_uploads_counter += 1

          upload, filename = find_upload(post, { attachment_id: attachment_id })

          puts "UPLOAD #{upload}"
          puts "FILENAME #{filename}"

          unless upload
            fail_count += 1
            puts "Upload recovery for post #{post_id} failed, upload id: #{attachment_id}"
            puts "Original upload: #{s}"
            puts "----------------------------------------------------------------------"
            next
          end

          puts "----------------------------------------------------------------------"
          # html = html_for_upload(upload, filename)
          # puts "The HTML to substitute is #{html}"
          # new_raw[uploads[missing_uploads_counter]] = html
          success_count += 1
        else
          puts "It's not a missing upload. Skipping."
          puts "----------------------------------------------------------------------"
          next
        end
      end

      # if new_raw != raw
      #   post['raw'] = new_raw
      #   post.save(validate: false)
      #   PostCustomField.create(post_id: post.id, name: "upload_fixed", value: true)
      #   success_count += 1
      # end
    end

    puts "", "imported #{success_count} attachments... failed: #{fail_count}"

  end

  def import_attachments_two
    puts '', 'importing missing attachments...'

    total_count = 0

    uploads = mysql_query <<-SQL
    SELECT n.parentid nodeid, a.filename, fd.userid, LENGTH(fd.filedata) AS dbsize, filedata, fd.filedataid
      FROM #{DB_PREFIX}attach a
      LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
      LEFT JOIN #{DB_PREFIX}node n on n.nodeid = a.nodeid
    SQL

    uploads.each do |upload|

      post_id = PostCustomField.where(name: 'import_id').where(value: upload[0]).first&.post_id
      post_id = PostCustomField.where(name: 'import_id').where(value: "thread-#{upload[0]}").first&.post_id unless post_id
      if post_id.nil?
        puts "Post for #{upload[0]} not found"
        next
      end
      
      missing = PostCustomField.where(post_id: post_id).where(name: Post::MISSING_UPLOADS)
      if missing.nil? || missing.empty?
        next
      end

      begin
          post = Post.find(post_id)
      rescue
          puts "Couldn't find post #{post_id}"
          next
      end

      filename = File.join(ATTACH_DIR, upload[2].to_s.split('').join('/'), "#{upload[5]}.attach")
      real_filename = upload[1]
      real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

      unless File.exists?(filename)
        # attachments can be on filesystem or in database
        # try to retrieve from database if the file did not exist on filesystem
        if upload[3].to_i == 0
          puts "Attachment file #{upload[5]} doesn't exist"
          next
        end

        tmpfile = 'attach_' + upload[5].to_s
        filename = File.join('/tmp/', tmpfile)
        File.open(filename, 'wb') { |f|
          f.write(upload[4])
        }
        return nil if filename.nil?
      end

      puts "POST ID: #{post_id}"
      puts "PATH IN FILESYSTEM: #{filename}"
      puts "FILENAME: #{real_filename}"

      total_count += 1

    end
    puts "Total uploads porcessed succesfully: #{total_count}"
  end

  def import_attachments
    puts '', 'importing missing attachments...'

    total_count = 0

    PostCustomField.where(name: Post::MISSING_UPLOADS).pluck(:post_id, :value).each do |post_id, uploads|
      post = Post.where(id: post_id)
      raw = post.first.raw
      new_raw = raw.dup 

      original_post_id = PostCustomField.where(name: 'import_id', post_id: post_id).first

      if original_post_id.nil?
        puts "Original post not found for #{post.first.id}"
        next
      end

      original_post_id = original_post_id.value


      uploads = mysql_query <<-SQL
        SELECT n.parentid nodeid, a.filename, fd.userid, LENGTH(fd.filedata) AS dbsize, filedata, fd.filedataid
          FROM attach a
          LEFT JOIN filedata fd ON fd.filedataid = a.filedataid
          LEFT JOIN node n on n.nodeid = a.nodeid
          WHERE n.parentid = #{original_post_id}
      SQL

      upload = uploads.first

      if upload.nil? || upload.empty?
        puts "Upload for #{post.first.id} not found"
        next
      end

      filename = File.join(ATTACH_DIR, upload[2].to_s.split('').join('/'), "#{upload[5]}.attach")
      real_filename = upload[1]
      real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

      unless File.exists?(filename)
        # attachments can be on filesystem or in database
        # try to retrieve from database if the file did not exist on filesystem
        if upload[3].to_i == 0
          puts "Attachment file #{upload[5]} doesn't exist"
          next
        end

        tmpfile = 'attach_' + upload[5].to_s
        filename = File.join('/tmp/', tmpfile)
        File.open(filename, 'wb') { |f|
          f.write(upload[4])
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



  def mysql_stream(sql)
    @client.query(sql, stream: true)
  end

  def mysql_query(sql)
    @client.query(sql)
  end
end

ImportScripts::EpicFixes.new.execute
