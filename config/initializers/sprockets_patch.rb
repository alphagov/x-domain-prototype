require "sprockets/directive_processor"

module SprocketsDirectivePatch
  def process_directives(directives)
    valid_directives = directives.reject do |line_number, name, *args|
      # Reject the directive if it is a 'link' but has more than 1 argument
      name == "link" && args.length > 1
    end
    super(valid_directives)
  end
end

Sprockets::DirectiveProcessor.prepend(SprocketsDirectivePatch)