# In test, we don't run the Bun/Tailwind build pipeline, but Propshaft raises
# when an asset referenced by helpers is missing. Provide minimal stub build
# outputs so controller/integration tests can render views.
if Rails.env.test?
  builds_dir = Rails.root.join("app", "assets", "builds")
  FileUtils.mkdir_p(builds_dir)

  css_path = builds_dir.join("application.css")
  js_path = builds_dir.join("application.js")

  File.write(css_path, "/* test stub */\n") unless css_path.file?
  File.write(js_path, "// test stub\n") unless js_path.file?
end
