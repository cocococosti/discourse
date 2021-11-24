# frozen_string_literal: true

require 'tiny_tds'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::Yafnet < ImportScripts::Base

  def initialize
    super

    @client = TinyTds::Client.new(
      host: ENV["DB_HOST"] || "0.0.0.0:1433",
      username: ENV["DB_USERNAME"] || "",
      password: ENV["DB_PASSWORD"] || "",
      database: ENV["DB_NAME"] || "",
      timeout: 60 # the user query is very slow
    )
  end

  def execute

  end

  def test
    puts "Testing ..."

    users = query(<<~SQL)
      SELECT top 10 *
      FROM yaf_User
    SQL

    puts users[0]
  end

  def query(sql)
    @client.execute(sql).to_a
  end

end

ImportScripts::Yafnet.new.perform
