module UserFilterHelper
  def current_path_with_filter(filter_type, filter_value)
    query_parameters = (request.query_parameters.clone || {})
    filter_value.nil? ? query_parameters.delete(filter_type) : query_parameters[filter_type] = filter_value
    query_string = query_parameters.map { |k, v| "#{k}=#{v}" }.join("&")
    "#{request.path_info}?#{query_string}"
  end

  def user_role_text
    "#{params[:role]} users".strip.humanize.capitalize
  end

  def two_step_abbr_tag
    tag.abbr("2SV", title: "Two step verification")
  end

  def title_from(filter_type)
    if filter_type == :two_step_status
      safe_join([two_step_abbr_tag, "Status"], " ")
    else
      filter_type.to_s.humanize.capitalize
    end
  end

  def user_filter_list_items(filter_type)
    items = case filter_type
            when :role
              filtered_user_roles
            when :permission
              Doorkeeper::Application
                .joins(:supported_permissions)
                .order("oauth_applications.name", "supported_permissions.name")
                .pluck("supported_permissions.id", "oauth_applications.name", "supported_permissions.name")
                .map { |e| [e[0], "#{e[1]} #{e[2]}"] }
            when :status
              User::USER_STATUSES
            when :organisation
              if is_super_org_admin?
                current_user.organisation.subtree.order(:name).joins(:users).uniq.map { |org| [org.id, org.name_with_abbreviation] }
              else
                Organisation.order(:name).joins(:users).uniq.map { |org| [org.id, org.name_with_abbreviation] }
              end
            when :two_step_status
              # rubocop:disable Style/WordArray
              [["true", "Enabled"], ["false", "Not set up"]]
              # rubocop:enable Style/WordArray
            end

    list_items = items.map do |item|
      if item.is_a? String
        item_id = item
        item_name = item.humanize
      else
        item_id = item[0].to_s
        item_name = item[1]
      end
      tag.li(
        link_to(item_name, current_path_with_filter(filter_type, item_id)),
        class: params[filter_type] == item_id ? "active" : "",
      )
    end

    list_items << tag.li(
      link_to(
        "All #{title_from(filter_type).pluralize}".html_safe,
        current_path_with_filter(filter_type, nil),
      ),
    )

    list_items.join("\n").html_safe
  end

  def filtered_user_roles
    current_user.manageable_roles
  end

  def value_from(filter_type)
    value = params[filter_type]
    return nil if value.blank?

    case filter_type
    when :organisation
      org = Organisation.find(value)
      if org.abbreviation.presence
        tag.abbr(org.abbreviation, title: org.name)
      else
        org.name
      end
    when :permission
      Doorkeeper::Application
        .joins(:supported_permissions)
        .where("supported_permissions.id = ?", value)
        .pick("oauth_applications.name", "supported_permissions.name")
        .join(" ")
    when :two_step_status
      if value == "true"
        "Enabled"
      else
        "Not set up"
      end
    else
      value.humanize.capitalize
    end
  end

  def any_filter?
    params[:filter].present? ||
      params[:role].present? ||
      params[:permission].present? ||
      params[:status].present? ||
      params[:organisation].present?
  end
end
