# -*- coding: utf-8 -*-
 
require 'date'
require 'rss'


# IDからシンボルを作る
def sym(base, id)
  (base + id.to_s).to_sym
end


# 検索クラス
class Satoshi
  attr_reader :last_fetch_time, :id


  # コンストラクタ
  def initialize(service, user_config, id)
    @service = service
    @last_config = Hash.new
    @result_queue = Array.new()
    @queue_lock = Mutex.new()
    @last_result_time = nil
    @last_fetch_time = Time.now
    @user_config = user_config
    @id = id
  end


  # コンフィグの初期化
  def init_user_config()
    @user_config[sym("rss_url", @id)] ||= ""
    @user_config[sym("rss_reverse", @id)] ||= false
  end


  # 設定画面の生成
  def setting(plugin)
    id = @id

    plugin.settings "フィード" + id.to_s do
      input("URL", sym("rss_url", id))
      boolean("新しい記事を優先する", sym("rss_reverse", id))
    end
  end


  # 日時文字列をパースする
  def parse_time(str)
    begin
      if str.class == Time then
        str
      else
        Time.parse(str)
      end
    rescue
      nil
    end
  end


  # 検索結果を取り出す
  def fetch()
    msg = nil

    @queue_lock.synchronize {
      if @user_config[sym("rss_reverse", @id)] then
        msg = @result_queue.pop
      else
        msg = @result_queue.shift
      end
    }

    if msg != nil then
      @last_fetch_time = Time.now
    end 

    # puts @urls.to_s + @result_queue.size.to_s

    return msg
  end


  # 検索する
  def search()
    begin
      url = @user_config[sym("rss_url", @id)]

      # 検索オプションが変わったら、キャッシュを破棄する
      is_reload = [sym("rss_url", @id)]
        .inject(false) { |result, key|
        result = result || (@user_config[key] != @last_config[key])

        @last_config[key] = @user_config[key]

        result
      }

      if is_reload then
        p "ID:" + @id.to_s + " setting changed"

        @queue_lock.synchronize {
          @result_queue.clear
          @last_result_time = nil
        }
      end

      if @user_config[sym("rss_url", @id)].empty? then
        return true
      end
 
      # RSSを読み込む
      rss = RSS::Parser.parse(@user_config[sym("rss_url", @id)], false)

      items = rss.items.select { |item|
        result_tmp = false

        if @last_result_time == nil then
          result_tmp = true
        elsif item.date != nil && @last_result_time < item.date then
          result_tmp = true
        else
          result_tmp = false
        end

        result_tmp
      }
  
      if items.size == 0 then
        return true
      end
  
      msgs = items.map { |item| 
        msg = Message.new(:message => (item.title + "\n" + item.link), :system => true)

        msg[:created] = item.date

        if defined?(rss.channel.image.url) then
          image_url = rss.channel.image.url
        elsif defined?(rss.channel.image.resource) then
          image_url = rss.channel.image.resource
        else
          image_url = MUI::Skin.get("icon.png")
        end

        msg[:user] = User.new(:id => -3939,
                              :idname => "RSS",
                              :name => rss.channel.title,
                              :profile_image_url => image_url)

        if item.date != nil && (@last_result_time == nil || @last_result_time < item.date) then
          @last_result_time = item.date
        end

        msg
      }
  
      p "new message:" + msgs.size.to_s
      p "last time:" + $last_time.to_s
  
      @queue_lock.synchronize {
        @result_queue.concat(msgs.reverse)
      }
    rescue => e
      puts e
      puts e.backtrace

      return false 
    end

    return true
  end
end


Plugin.create :rss_reader do 
  # グローバル変数の初期化
  $satoshis = []

  # 設定画面
  settings "RSS混ぜ込み" do
    $satoshis.each {|satoshi|
      satoshi.setting(self)
    }
 
    boolean("日本語のツイートのみ", :rss_japanese)
    adjustment("ポーリング間隔（秒）", :rss_period, 1, 6000)
    adjustment("混ぜ込み間隔（秒）", :rss_insert_period, 1, 600)
    input("プレフィックス", :rss_prefix)

    settings "カスタムスタイル" do
      boolean("カスタムスタイルを使う", :rss_custom_style)
      fontcolor("フォント", :rss_font_face, :rss_font_color)
      color("背景色", :rss_background_color)
    end
  end 


  # カスタムスタイルを選択する
  def choice_style(message, key, default)
    if !UserConfig[:rss_custom_style] then
      default
    elsif message[:rss] then
      UserConfig[key]
    else
      default
    end
  end


  # 更新用ループ
  def search_loop(service)
    Reserver.new(UserConfig[:rss_period]){
      search_url(service) 
      search_loop service
    } 
  end
  
  # 混ぜ込みループ
  def insert_loop(service)
    Reserver.new(UserConfig[:rss_insert_period]){
      begin
        fetch_order = $satoshis.select(){ |a| a != nil }.sort() { |a, b|
          a.last_fetch_time <=> b.last_fetch_time
        }

        msg = nil

        fetch_order.each {|satoshi|
          msg = satoshi.fetch()

          if msg != nil then
            break
          end
        }

        if msg != nil then
          msg[:modified] = Time.now
          msg[:rss] = true
  
          # タイムラインに登録
          if defined?(timeline)
            timeline(:home_timeline) << [msg]
          else
            Plugin.call(:update, service, [msg])
          end

          # puts "last message :" + $result_queue.size.to_s
        end

      rescue => e
        puts e
        puts e.backtrace

      ensure
        insert_loop service

      end
    } 
  end
  

  # 検索
  def search_url(service)
    begin
      $satoshis.each { |satoshi|
        result = satoshi.search()

        if !result then
          msg = Message.new(:message => "フィードの取得に失敗しました。 " + UserConfig[sym("rss_url", satoshi.id)], :system => true)

          msg[:user] = User.new(:id => -3939,
                                :idname => "RSS",
                                :name => "エラー",
                                :profile_image_url => MUI::Skin.get("icon.png"))

          # タイムラインに登録
          if defined?(timeline)
            timeline(:home_timeline) << [msg]
          else
            Plugin.call(:update, service, [msg])
          end
        end
      }
    rescue => e
      puts e
      puts e.backtrace
    end
  end

  # 起動時処理
  on_boot do |service|
    (0..5 - 1).each {|i|
      $satoshis << Satoshi.new(service, UserConfig, i + 1)
    }

    # コンフィグの初期化
    UserConfig[:rss_period] ||= 60
    UserConfig[:rss_insert_period] ||= 3
    UserConfig[:rss_background_color] ||= [65535, 65535, 65535]
    UserConfig[:rss_custom_style] ||= false
    UserConfig[:rss_font_face] ||= 'Sans 10'
    UserConfig[:rss_font_color] ||= [0, 0, 0]

    $satoshis.each {|satoshi|
      satoshi.init_user_config
    }
  
    search_loop service
    insert_loop service
  end

  # 背景色決定
  filter_message_background_color do |message, color|
    begin
      color = choice_style(message.message, :rss_background_color, color)

      [message, color]

    rescue => e
      puts e
      puts e.backtrace
    end
  end


  # フォント色決定
  filter_message_font_color do |message, color|
    begin
      color = choice_style(message.message, :rss_font_color, color)

      [message, color]

    rescue => e
      puts e
      puts e.backtrace
    end
  end


  # フォント決定
  filter_message_font do |message, font|
    begin
      font = choice_style(message.message, :rss_font_face, font)

      [message, font]

    rescue => e
      puts e
      puts e.backtrace
    end
  end
end
