require "./lucky_swagger/*"
require "./version"
require "habitat"
require "lucky"

module LuckySwagger
  Habitat.create do
    setting path : String = "/swagger"

    setting host : String = Lucky::Server.settings.host
    setting port : Int32  = Lucky::Server.settings.port

    setting title : String
    setting version : String
    setting description : String? = nil
    setting terms_url : String? = nil
    setting license : Swagger::License? = nil
    setting contact : Swagger::Contact? = nil
    setting authorizations : Array(Swagger::Authorization)? = nil

    setting debug_mode : Bool = false

    setting namespaces : Array(String) = ["API::V1"]
  end
end
