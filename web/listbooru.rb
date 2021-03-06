require "dotenv"
Dotenv.load

require "sinatra"
require "digest/md5"
require "redis"
require "json"
require "aws-sdk"
require "cityhash"

set :port, ENV["SINATRA_PORT"]

REDIS = Redis.new
SQS = Aws::SQS::Client.new(
  credentials: Aws::Credentials.new(
    ENV["AMAZON_KEY"],
    ENV["AMAZON_SECRET"]
  ),
  region: ENV["AWS_REGION"]
)

helpers do
  def in_groups_of(array, number, fill_with = nil)
    if number.to_i <= 0
      raise ArgumentError,
        "Group size must be a positive integer, was #{number.inspect}"
    end

    if fill_with == false
      collection = array
    else
      # size % number gives how many extra we have;
      # subtracting from number gives how many to add;
      # modulo number ensures we don't add group of just fill.
      padding = (number - array.size % number) % number
      collection = array.dup.concat(Array.new(padding, fill_with))
    end

    if block_given?
      collection.each_slice(number) { |slice| yield(slice) }
    else
      collection.each_slice(number).to_a
    end
  end

  def normalize_query(query)
    tokens = query.downcase.scan(/\S+/)
    return "no-matches" if tokens.size == 0
    return "no-matches" if tokens.any? {|x| x =~ /\*/}
    return "no-matches" if tokens.all? {|x| x =~ /^-/}
    tokens.join(" ")
  end

  def send_sqs_message(string, options = {})
    SQS.send_message(
      options.merge(
        message_body: string,
        queue_url: ENV["LISTBOORU_SQS_URL"]
      )
    )
  rescue Exception => e
    logger.error(e.to_s)
    logger.error(e.backtrace.join("\n"))
  end

  def send_sqs_messages(strings, options = {})
    in_groups_of(strings, 10) do |batch|
      entries = batch.compact.map do |x| 
        options.merge(message_body: x, id: CityHash.hash64(x).to_s)
      end

      SQS.send_message_batch(queue_url: ENV["LISTBOORU_SQS_URL"], entries: entries)
    end
  rescue Exception => e
    logger.error(e.to_s)
    logger.error(e.backtrace.join("\n"))
  end

  def aggregate_global(user_id)
    queries = REDIS.smembers("users:#{user_id}")
    limit = ENV["MAX_POSTS_PER_SEARCH"].to_i

    if queries.any? && !REDIS.exists("searches/user:#{user_id}")
      REDIS.zunionstore "searches/user:#{user_id}", queries.map {|x| "searches:#{x}"}
      send_sqs_messages(queries.map {|x| "clean global\n#{user_id}\n#{x}"})
    end

    REDIS.zrevrange("searches/user:#{user_id}", 0, limit)
  end

  def aggregate_named(user_id, name)
    queries = REDIS.smembers("users:#{user_id}:#{name}")
    limit = ENV["MAX_POSTS_PER_SEARCH"].to_i

    if queries.any? && !REDIS.exists("searches/user:#{user_id}:#{name}")
      REDIS.zunionstore "searches/user:#{user_id}:#{name}", queries.map {|x| "searches:#{x}"}
      send_sqs_messages(queries.map {|x| "clean named\n#{user_id}\n#{name}\n#{x}"})
    end

    REDIS.zrevrange("searches/user:#{user_id}:#{name}", 0, limit)
  end
end

before "/users" do
  if params["key"] != ENV["LISTBOORU_AUTH_KEY"]
    halt 401
  end
end

get "/" do
  redirect "/index.html"
end

get "/users" do
  user_id = params["user_id"]
  name = params["name"]

  if name
    results = aggregate_named(user_id, name)
  else
    results = aggregate_global(user_id)
  end

  results.to_json
end

