module ApplicationHelper
  def active_nav?(*paths)
    current = request.path
    paths.any? { |path| current == path || current.start_with?("#{path}/") }
  end
end
