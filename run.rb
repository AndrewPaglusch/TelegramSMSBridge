#!/usr/bin/env ruby
require 'twilio-ruby'
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

def send_sms(msg,pic = nil)
  client = Twilio::REST::Client.new(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
  client.api.account.messages.create(from: TWILIO_NUMBER, to: REAL_NUMBER, body: msg)
rescue => e
  puts e.message
end

def get_sms()
  return_data = Hash.new
  client = Twilio::REST::Client.new(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
  client.api.account.messages.list(from: REAL_NUMBER).each do |m|
    return_data[m.date_sent] = {:from => m.from, :message => m.body}
    m.delete #delete the message
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
      #send message via SMS
      send_sms(m[:message])
    end
  end

  ### SMS -> Telegram
  new_sms_messages = get_sms
  if new_sms_messages.empty? == false
    new_sms_messages.each do |k,m|
      send_telegram(m[:message])
    end
  end

  sleep SLEEP_TIME
end
