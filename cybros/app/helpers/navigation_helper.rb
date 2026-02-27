module NavigationHelper
  def sidebar_nav_item(label:, path:, icon_class:, active_paths: [path], data: {}, tooltip: label)
    li_classes = "is-drawer-close:tooltip is-drawer-close:tooltip-right is-drawer-close:flex is-drawer-close:justify-center"
    link_classes = [
      "w-full",
      "gap-2",
      "justify-start",
      "is-drawer-close:justify-center",
      "is-drawer-close:px-0",
      "is-drawer-close:btn-square",
      ("menu-active" if active_nav?(*Array(active_paths)))
    ].compact.join(" ")

    content_tag(:li, class: li_classes, data: { tip: tooltip }) do
      link_to(path, class: link_classes, data: data) do
        safe_join(
          [
            content_tag(:span, "", class: icon_class),
            content_tag(:span, label, class: "is-drawer-close:hidden")
          ]
        )
      end
    end
  end

  def sidebar_section_title(text)
    content_tag(:div, class: "px-2 pt-1") do
      content_tag(:div, text, class: "text-[11px] font-semibold tracking-wide opacity-60 is-drawer-close:hidden")
    end
  end

  def settings_nav_item(label:, path:, icon_class:, active_paths: [path])
    link_classes = [
      "rounded-xl",
      "font-medium",
      "gap-2",
      ("menu-active" if active_nav?(*Array(active_paths)))
    ].compact.join(" ")

    content_tag(:li) do
      link_to(path, class: link_classes) do
        safe_join(
          [
            content_tag(:span, "", class: icon_class),
            content_tag(:span, label)
          ]
        )
      end
    end
  end
end

