#!/usr/bin/env ruby
require 'ruby-bandwidth'
require 'json'

require_relative 'settings.rb' #Settings

def api_query(query)
  url = URI.parse(query)
  request = Net::HTTP.new(url.host, url.port)
  request.use_ssl = url.scheme == 'https'
  begin
    response = request.start {|req| req.get(url) }
    return response.body
  rescue
    return $!.message
  end
end

def sms_log_disk(message_id)
  #save message_id to disk
  open('read_messages.txt', 'a') { |f| f.puts message_id }
end

def sms_on_disk?(message_id)
  #return true/fals if message_id
  #is logged to disk
  IO.foreach('read_messages.txt') do |l|
    return true if l.chomp == message_id
  end
  return false
end

def sms_purge_expired(api_messages)
  #read all messages from disk and
  #remove messages that we didn't get from API

  disk_contents = File.read('read_messages.txt')
  IO.foreach('read_messages.txt') do |l|
    found = false
    api_messages.each do |k,v|
      found = true if v[:message_id] == l.chomp
    end
    disk_contents.gsub!(l, '') if found == false
  end
  File.write('read_messages.txt', disk_contents)
end

def send_sms(msg)
  client = Bandwidth::Client.new(:user_id => BANDWIDTH_USER_ID, :api_token => BANDWIDTH_API_TOKEN, :api_secret => BANDWIDTH_API_SECRET)
  message = Bandwidth::Message.create(client, {:from => BANDWIDTH_NUMBER, :to => REAL_NUMBER, :text => msg})
rescue => e
  puts e.message
end

def send_mms(msg,file_path)
  client = Bandwidth::Client.new(:user_id => BANDWIDTH_USER_ID, :api_token => BANDWIDTH_API_TOKEN, :api_secret => BANDWIDTH_API_SECRET)

  #generate filename and upload : <<md5>>_name.jpg
  file_name = "#{Digest::MD5.file(file_path)}_#{file_path}"
  Bandwidth::Media.upload(client, file_name, File.open(file_path, "r"), "image/png")
  file = (Bandwidth::Media.list(client).select {|f| f[:media_name] == file_name})[0]

  message = Bandwidth::Message.create(client, {:from => BANDWIDTH_NUMBER, :to => REAL_NUMBER, :text => msg, :media => file[:content]}) 
rescue => e
  puts e.message
end

def get_sms()
  return_data = Hash.new
  client = Bandwidth::Client.new(:user_id => BANDWIDTH_USER_ID, :api_token => BANDWIDTH_API_TOKEN, :api_secret => BANDWIDTH_API_SECRET)
  messages = Bandwidth::Message.list(client, {:state => "received", :from => REAL_NUMBER})
  messages.each do |m|
    return_data[m[:time]] = {:message_id => m[:message_id], :from => m[:from], :message => m[:text]}
  end
  return return_data
end

def send_telegram(message)
  uri = URI("https://api.telegram.org/bot#{TELEGRAM_BOT_KEY}/sendMessage")
  res = Net::HTTP.post_form(uri, 'chat_id' => TELEGRAM_USER_ID, 'text' => message)
rescue
  puts "Failed to send Telegram alert! Reason: " + $!.message
end

def get_telegram(last_offset)
  telegram_json_raw = api_query("https://api.telegram.org/bot#{TELEGRAM_BOT_KEY}/getUpdates?offset=#{last_offset}")
  telegram_json_parsed =  JSON.parse(telegram_json_raw, :symbolize_names => true)

  #check if API call was success
  return if telegram_json_parsed[:ok] != true

  return_data = Hash.new
  telegram_json_parsed[:result].each do |m|
    return_data[m[:update_id]] = { :first_name => m[:message][:from][:first_name], :message => m[:message][:text] }
  end

  return return_data
end

telegram_last_offset = 0
loop do

  ### Telegram -> SMS
  new_telegram_messages = get_telegram(telegram_last_offset)
  if new_telegram_messages.empty? == false
    #update the offset so that we don't get the same message next time
    telegram_last_offset = new_telegram_messages.keys.last.to_i + 1

    #parse the new messages
    new_telegram_messages.each do |k,m|
      puts "New Telegram: #{m[:message]}"
      #send message via SMS
      send_sms(m[:message])
    end
  end

  ### SMS -> Telegram
  sms_messages = get_sms
  sms_purge_expired(sms_messages)

  if sms_messages.empty? == false
    sms_messages.each do |k,m|
      if ! sms_on_disk?(m[:message_id])
        #save to disk so we don't process again
        sms_log_disk(m[:message_id])
        puts "New SMS: #{m[:message]}"
        send_telegram(m[:message])
      end
    end
  end

  sleep SLEEP_TIME
end
