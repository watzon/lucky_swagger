require "swagger"
require "swagger/http/handler"

module LuckySwagger
  annotation Action; end

  class Middleware
    getter api_handler, web_handler

    def initialize
      settings = LuckySwagger.settings
      builder = Swagger::Builder.new(
        title: settings.app_name,
        version: settings.version,
        description: settings.description,
        terms_url: settings.terms_url,
        authorizations: [
          Swagger::Authorization.jwt(description: "Use JWT Auth"),
        ]
      )

      annotated_actions = {% begin %}
        {
          {% for action in Lucky::Action.all_subclasses %}
            {% if (ann = action.annotation(LuckySwagger::Action)) && !action.abstract? %}
              {{ action }} => {
                scopes: {{ ann[:scopes] }},
                summary: {{ ann[:summary] }},
                responses: {{ ann[:responses] }},
                request: {{ ann[:request] }},
              },
            {% end %}
          {% end %}
        }
      {% end %}

      # Add routes
      controllers = Hash(String, Array(Swagger::Action)).new
      Lucky.router.routes.each do |(method, path, action)|
        next unless path.starts_with?(settings.uri)
        annotated_action = annotated_actions[action]?

        scopes = annotated_action.try(&.[:scopes]) || action.to_s.split("::")
        scope = scopes.first
        description = annotated_action.try(&.[:summary]) || scopes[1..].join(" ")

        query_params = action.query_param_declarations.map do |param|
          crystal_def_to_swagger_param(param)
        end

        path_params, path = lucky_route_to_swagger_params(path)

        controllers[scope] ||= [] of Swagger::Action
        controllers[scope].unshift(
          Swagger::Action.new(
            method: method.to_s,
            route: path,
            description: description,
            parameters: path_params + query_params,
            request: annotated_action.try(&.[:request]),
            responses: annotated_action.try(&.[:responses]) || [
              Swagger::Response.new("200", "Success response"),
            ],
          )
        )
      end

      controllers.each do |scope, actions|
        builder.add(Swagger::Controller.new(scope, "", actions))
      end

      if ENV["LUCKY_ENV"]? == "production"
        uri = URI.parse(ENV["APP_DOMAIN"])
        host = uri.host
        port = uri.port
      else
        host = Lucky::ServerSettings.host
        port = Lucky::ServerSettings.port
      end

      @api_handler = Swagger::HTTP::APIHandler.new(builder.built, File.join("#{host}:#{port}", settings.uri))
      @web_handler = Swagger::HTTP::WebHandler.new(settings.uri, api_handler.api_url)
    end

    # Convert a crystal type definition into a swagger parameter.
    # Examples:
    #   crystal_def_to_swagger_param("id : Int32") # => Swagger::Parameter.new("id", "path", "int32")
    #   crystal_def_to_swagger_param("id : Int32 | ::Nil") # => Swagger::Parameter.new("id", "path", "int32", required: false)
    #   crystal_def_to_swagger_param("id : Int32 | ::Nil = 1") # => Swagger::Parameter.new("id", "path", "int32", required: false, default_value: 1)
    #   crystal_def_to_swagger_param("id : Int32 | String") # => Swagger::Parameter.new("id", "path", "int32 | string")
    private def crystal_def_to_swagger_param(crystal_def)
      name, type = crystal_def.split(" : ")
      type = type.split(" | ").map do |t|
        if t == "::Nil"
          "null"
        else
          t.downcase
        end
      end.join(" | ")

      if type.includes?("=")
        type, default_value = type.split("=").map(&.strip)
        default_value = default_value.to_i if type == "int32"
      end

      Swagger::Parameter.new(name, "query", type, required: !type.includes?("null"), default_value: default_value)
    end

    # Convert a Lucky route definition into a list of swagger parameters. Returns the list, and the
    # path in swagger format.
    #
    # Examples:
    #   lucky_route_to_swagger_params("/users/:id") # => [Swagger::Parameter.new("id", "path", "string")], "/users/{id}"
    #   lucky_route_to_swagger_params("/users/:id/comments/:comment_id") # => [Swagger::Parameter.new("id", "path", "string"), Swagger::Parameter.new("comment_id", "path", "string")], "/users/{id}/comments/{comment_id}"
    #   lucky_route_to_swagger_params("/users/?:id") # => [Swagger::Parameter.new("id", "path", "string", required: false)], "/users/{id}"
    #   lucky_route_to_swagger_params("/posts/*") # => [Swagger::Parameter.new("glob", "path", "string")], "/posts/{glob}"
    #   lucky_route_to_swagger_params("/posts/*date") # => [Swagger::Parameter.new("date", "path", "string")], "/posts/{date}"
    def lucky_route_to_swagger_params(route)
      params = [] of Swagger::Parameter
      path = route.gsub(/:(\w+)/) do |match|
        name = $1
        params << Swagger::Parameter.new(name, "path", "string")
        "{#{name}}"
      end

      path = path.gsub(/(\w+)\*/) do |match|
        name = $1
        params << Swagger::Parameter.new(name, "path", "string")
        "{#{name}}"
      end

      {params, path}
    end
  end
end
