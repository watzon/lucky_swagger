require "swagger"
require "swagger/http/handler"

module LuckySwagger
  class Middleware
    getter api_handler : Swagger::HTTP::APIHandler
    getter web_handler : Swagger::HTTP::WebHandler

    def initialize
      settings = LuckySwagger.settings
      builder = Swagger::Builder.new(
        title: settings.title,
        version: settings.version,
        description: settings.description,
        terms_url: settings.terms_url,
        license: settings.license,
        contact: settings.contact,
        authorizations: settings.authorizations,
      )

      # Build a list of controllers using the namespace_actions,
      # and add them to the builder.
      controllers = build_controllers
      controllers.each do |(namespace, actions)|
        builder.add(Swagger::Controller.new(namespace, "", actions))
      end

      # Assign the handlers
      @api_handler = Swagger::HTTP::APIHandler.new(builder.built, File.join("#{settings.host}:#{settings.port}", settings.path))
      @web_handler = Swagger::HTTP::WebHandler.new(settings.path, api_handler.api_url)
    end

    # Build the swagger controllers from the namespace_actions.
    def build_controllers
      {% begin %}
        controllers = {} of String => Array(Swagger::Action)
        all_actions = Lucky.router.routes.reduce({} of Lucky::Action.class => NamedTuple(method: Symbol, path: String)) do |hash, (method, path, action)|
          hash[action] = {method: method, path: path}
          hash
        end

        # Build actions based on which lucky actions have a `LuckySwagger::Action` annotation.
        # Other actions are ignored, even if they're in the correct namespace.
        {% for action in Lucky::Action.all_subclasses.reject(&.abstract?) %}
          {% if ann = action.annotation(LuckySwagger::Action) %}
            %namespace = {{ ann[:controller] }} || {{ action.id }}.name.split("::")[-2]
            %method = all_actions[{{ action.id }}][:method].to_s.upcase
            %path_params, %path = lucky_route_to_swagger_params(all_actions[{{ action.id }}][:path])
            %query_params = {{ action.id }}.query_param_declarations.map do |param|
              crystal_def_to_swagger_param(param)
            end

            controllers[%namespace] ||= [] of Swagger::Action
            controllers[%namespace] << Swagger::Action.new(
              method: %method,
              route: %path,
              summary: {{ ann[:summary] }},
              description: {{ ann[:description] }},
              parameters: %path_params + %query_params,
              request: {{ ann[:request] }},
              responses: {{ ann[:responses] }},
              authorization: {{ ann[:authorization] }} || false,
              deprecated: {{ ann[:deprecated] }} || false,
            )
          {% end %}
        {% end %}

        controllers
      {% end %}
    end

    # Convert a crystal type definition into a swagger parameter.
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
