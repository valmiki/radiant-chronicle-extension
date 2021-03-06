module Chronicle::PageExtensions
  def self.included(base)
    base.class_eval do
      simply_versioned
      alias_method_chain :update_without_callbacks, :draft_versioning
      alias_method_chain :save_page_parts, :draft_versioning
      alias_method_chain :find_by_url, :draft_versioning
      alias_method_chain :simply_versioned_create_version, :extra_version_attributes
      alias_method_chain :url, :draft_awareness
      alias_method_chain :render, :draft_layouts
      
      # Switch callback chain order so page parts are saved to the version
      create_version_callback = @after_save_callbacks.detect {|c| c.method == :simply_versioned_create_version }
      @after_save_callbacks.delete(create_version_callback)
      @after_save_callbacks.unshift(create_version_callback)
    end
    
    base.send :include, ActiveRecord::Diff
    base.send :alias_method_chain, :diff, :page_associations
    base.send(:diff, {:include => [:layout_id, :class_name, :status_id]})
  end
  
  def update_without_callbacks_with_draft_versioning
    if self.status_id < Status[:published].id # Draft or Reviewed
      update_with_lock([self.class.locking_column]) # Only update the locking column, not other attributes
      true # Don't save page; versioning callbacks will save it in the versions table
    else
      update_without_callbacks_without_draft_versioning
    end
  end
  
  def save_page_parts_with_draft_versioning
    if self.status_id < Status[:published].id # Draft or Reviewed
      # Don't save parts to the live page; callbacks will add them to the versioned page
      @page_parts = nil
      true
    else
      save_page_parts_without_draft_versioning
    end
  end
  
  def simply_versioned_create_version_with_extra_version_attributes
    with_associated_parts_in_attributes do
      simply_versioned_create_version_without_extra_version_attributes
    end
    
    self.versions.current.update_attributes(:slug => slug, :status_id => status_id)
  end
  
  # Works the same as #find_by_url when in live mode, but in dev mode, finds
  # the URL using the most current versions (which may be draft versions ahead
  # of the live version)
  def find_by_url_with_draft_versioning(url, live = true, clean = true)
    if live
      find_by_url_without_draft_versioning(url, live, clean)
    else
      return nil if virtual?
      url = clean_url(url) if clean
      my_url = self.url(live)
      if (my_url == url) && (not live or published?)
        self.current
      elsif (url =~ /^#{Regexp.quote(my_url)}([^\/]*)/)
        slug_child = current_children.find {|child| child.slug == $1 }
        if slug_child
          found = slug_child.find_by_url(url, live, clean)
          return found if found
        end
        current_children.each do |child|
          found = child.find_by_url(url, live, clean)
          return found if found
        end
        file_not_found_types = ([FileNotFoundPage] + FileNotFoundPage.descendants)
        file_not_found_names = file_not_found_types.collect { |x| x.name }
        condition = (['class_name = ?'] * file_not_found_names.length).join(' or ')
        condition = "status_id = #{Status[:published].id} and (#{condition})" if live
        file_not_found_page = children.find(:first, :conditions => [condition] + file_not_found_names)
        file_not_found_page.current if file_not_found_page
      end
    end
  end
  
  # The most recent version of the page, possibly ahead of the live version
  def current
    self.versioned? ? self.versions.current.instance : self
  end
  alias_method :current_dev, :current

  # The most recent live version of the page
  def current_live
    self.versioned? ? self.versions.current_live.instance : self
  end
  
  # The most recent versions of children
  def current_children
    children.map {|c| c.current }
  end
  
  # The #url method should be aware that it's a child of a draft
  def url_with_draft_awareness(live = true)
    if !live && parent
      parent.current.child_url(self)
    else
      url_without_draft_awareness
    end
  end
  
  def render_with_draft_layouts
    if layout
      if layout.versioned? && dev?(request)
        parse_object(layout.current)
      else
        parse_object(layout)
      end
    else
      render_part(:body)
    end
  end
  
  def with_associated_parts_in_attributes(&block)
    real_attributes = self.attributes
    write_attribute "parts", self.parts.map {|p| p.attributes }
    block.call
    self.attributes = real_attributes if self.status_id < Status[:published].id
  end
  
  def diff_with_page_associations(other_record = nil)
    if other_record.nil?
      parts_diff = self.parts.map do |part|
        [part.attributes_for_diff]
      end
    else
      old_record, new_record = self, other_record
      parts_diff = new_record.parts.map do |new_part|
        old_part = old_record.part(new_part.name)
        new_part_attributes = new_part.attributes_for_diff
        if old_part.nil?
          [nil, new_part_attributes] # Added part
        else
          old_part_attributes = old_part.attributes_for_diff
          if old_part_attributes == new_part_attributes # Because #uniq doesn't work to eliminate duplicate hashes in an array
            [new_part_attributes] # Unchanged part
          else
            [old_part_attributes, new_part_attributes] # Changed part
          end
        end
      end
      deleted_part_names = old_record.parts.map(&:name) - new_record.parts.map(&:name)
      deleted_part_names.each do |name|
        old_part = old_record.part(name)
        parts_diff << [old_part.attributes_for_diff, nil] # Deleted part
      end
    end
    diff_without_page_associations(other_record).merge(:parts => parts_diff)
  end
  
  def versions_with_limit(limit)
    self.versions.find(:all, :limit => limit)
  end
end