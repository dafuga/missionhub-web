 require 'name_uniqueness_validator'

class Organization < ActiveRecord::Base
  attr_accessor :person_id

  has_ancestry
  belongs_to :importable, polymorphic: true
  has_many :roles, inverse_of: :organization
  has_many :group_labels
  has_many :activities, dependent: :destroy
  has_many :target_areas, through: :activities
  has_many :organization_memberships, dependent: :destroy
  has_many :people, through: :organizational_roles
  has_many :contact_assignments
  has_many :keywords, class_name: 'SmsKeyword'
  has_many :surveys, dependent: :destroy
  has_many :survey_elements, through: :surveys
  has_many :questions, through: :surveys
  has_many :all_questions, through: :surveys, source: :all_questions
  has_many :followup_comments
  has_many :organizational_roles, inverse_of: :organization
  has_many :leaders, through: :organizational_roles, source: :person, conditions: {'organizational_roles.role_id' => Role.leader_ids}, order: "ministry_person.lastName, ministry_person.preferredName, ministry_person.firstName", uniq: true
  has_many :admins, through: :organizational_roles, source: :person, conditions: {'organizational_roles.role_id' => Role::ADMIN_ID}, order: "ministry_person.lastName, ministry_person.preferredName, ministry_person.firstName", uniq: true
  has_many :all_contacts, through: :organizational_roles, source: :person, conditions: ["organizational_roles.role_id = ?", Role::CONTACT_ID]
  has_many :contacts, through: :organizational_roles, source: :person, conditions: ["organizational_roles.role_id = ? AND organizational_roles.followup_status <> 'do_not_contact'", Role::CONTACT_ID]
  has_many :dnc_contacts, through: :organizational_roles, source: :person, conditions: {'organizational_roles.role_id' => Role::CONTACT_ID, 'organizational_roles.followup_status' => 'do_not_contact'}
  has_many :completed_contacts, through: :organizational_roles, source: :person, conditions: {'organizational_roles.role_id' => Role::CONTACT_ID, 'organizational_roles.followup_status' => 'completed'}
  has_many :inprogress_contacts, through: :contact_assignments, source: :person
  has_many :no_activity_contacts, through: :organizational_roles, source: :person, conditions: {'organizational_roles.role_id' => Role::CONTACT_ID, 'organizational_roles.followup_status' => 'uncontacted'}
  has_many :rejoicables
  has_many :groups
  has_many :surveys # duplicate of the above's "has_many :surveys, dependent: :destroy"
  Rejoicable::OPTIONS.each do |option|
    has_many :"#{option}_contacts", :through => :rejoicables, source: :person, conditions: {'rejoicables.what' => option}, uniq: true
  end

  default_value_for :show_sub_orgs, true

  validates_presence_of :name, :terminology#, :person_id
  validates :name, :name_uniqueness => true

  @queue = :general
  after_create :create_admin_user, :notify_admin_of_request
  
  serialize :settings, Hash

  state_machine :status, initial: :requested do
    state :requested
    state :active
    state :denied
    state :inactive

    event :approve do
      transition :requested => :active
    end
    after_transition :on => :approve, :do => :notify_user

    event :deny do
      transition :requested => :denied
    end
    after_transition :on => :deny, :do => :notify_user_of_denial

    event :disable do
      transition any => :inactive
    end
    end

    def to_s() name; end

    def self_and_children
      [self] + children
    end

    # def children_surveys
    #   Survey.where(organization_id: child_ids)
    # end

    def self_and_children_ids
      @self_and_children_ids ||= [id] + child_ids
    end

    def self_and_children_surveys
      Survey.where(organization_id: self_and_children_ids)
    end

    def self_and_children_keywords
      SmsKeyword.where(organization_id: self_and_children_ids)
    end

    def self_and_children_questions
      @self_and_children_questions ||= self_and_children_surveys.collect(&:questions).flatten.uniq
    end

    def unassigned_people
      Person.joins("INNER JOIN organizational_roles ON organizational_roles.person_id = #{Person.table_name}.#{Person.primary_key} AND organizational_roles.organization_id = #{self.id} AND organizational_roles.role_id = '#{Role::CONTACT_ID}' AND followup_status <> 'do_not_contact' LEFT JOIN contact_assignments ON contact_assignments.person_id = #{Person.table_name}.#{Person.primary_key}  AND contact_assignments.organization_id = #{self.id}").where('contact_assignments.id' => nil)
    end

    def roles
      Role.where("organization_id = 0 or organization_id = #{id}")
    end

    def <=>(other)
      name <=> other.name
    end

    def validation_method_enum # ???
      ['relay'] 
    end

    def terminology_enum
      Organization.connection.select_values("select distinct(terminology) term from organizations order by term")
    end

    def name_with_keyword_count
      "#{name} (#{keywords.count})"
    end

    def add_member(person_id)
      OrganizationMembership.find_or_create_by_person_id_and_organization_id(person_id, id) 
    end

    def add_leader(person, current_person)
      person_id = person.is_a?(Person) ? person.id : person
      add_member(person_id)
      begin
        OrganizationalRole.find_or_create_by_person_id_and_organization_id_and_role_id(person_id, id, Role::LEADER_ID, :added_by_id => current_person.id)
      rescue => error
        @save_retry_count =  (@save_retry_count || 5)
        retry if( (@save_retry_count -= 1) > 0 )
        raise error
      end
    end

    def add_contact(person)
      person_id = person.is_a?(Person) ? person.id : person
      add_member(person_id)
      begin
        OrganizationalRole.find_or_create_by_person_id_and_organization_id_and_role_id(person_id, id, Role::CONTACT_ID)
      rescue => error
        @save_retry_count =  (@save_retry_count || 5)
        retry if( (@save_retry_count -= 1) > 0 )
        raise error
      end
    end

    def add_admin(person)
      person_id = person.is_a?(Person) ? person.id : person
      add_member(person_id)
      OrganizationalRole.find_or_create_by_person_id_and_organization_id_and_role_id(person_id, id, Role::ADMIN_ID)
    end

    def add_involved(person)
      person_id = person.is_a?(Person) ? person.id : person
      add_member(person_id)
      OrganizationalRole.find_or_create_by_person_id_and_organization_id_and_role_id(person_id, id, Role::INVOLVED_ID)
    end

    def remove_contact(person)
      person_id = person.is_a?(Person) ? person.id : person
      unless Person.find(person_id).organizational_roles.where("organization_id = ? AND role_id <> ?", id, Role::CONTACT_ID).first
        OrganizationMembership.where(person_id: person_id, organization_id: id).first.try(:destroy)
      end
      OrganizationalRole.where(person_id: person_id, organization_id: id, role_id: Role::CONTACT_ID).first.try(:destroy)
    end

    def remove_leader(person)
      person_id = person.is_a?(Person) ? person.id : person
      unless Person.find(person_id).organizational_roles.where("organization_id = ? AND role_id <> ?", id, Role::LEADER_ID).first
        OrganizationMembership.where(person_id: person_id, organization_id: id).first.try(:destroy)
      end
      OrganizationalRole.where(person_id: person_id, organization_id: id, role_id: Role::LEADER_ID).first.try(:destroy)
      person.remove_assigned_contacts(self)
    end

    def move_contact(person, to_org, keep_contact)  
      @followup_comments = followup_comments.where(contact_id: person.id)
      @rejoicables = rejoicables.where(person_id: person.id)
      if keep_contact == "false"
        remove_contact(person)
        # move call followup comments
        @followup_comments.update_all(organization_id: to_org.id)
        @rejoicables.update_all(organization_id: to_org.id)
      else
        # copy followup comments
        @followup_comments.each do |fc|
          to_org.followup_comments.create(fc.attributes.slice(:contact_id, :commenter_id, :status, :comment, :updated_at, :created_at, :deleted_at))
          @rejoicables.where(followup_comment_id: fc.id).each do |r|
            to_org.rejoicables.create(r.attributes.slice(:person_id, :created_by_id, :what, :updated_at, :created_at, :deleted_at))
          end
        end
      end

      to_org.add_contact(person)
      FollowupComment.where(organization_id: id, contact_id: person.id).update_all(organization_id: to_org.id)
    end

    def create_admin_user
      add_admin(Person.find(self.person_id)) if person_id
    end 

    def notify_admin_of_request
      begin 
        if parent
          update_column(:status, 'active')
        else
          OrganizationMailer.enqueue.notify_admin_of_request(self.id)
        end
      rescue ActiveRecord::RecordNotFound
      end
    end

    def notify_new_leader(person, added_by)
      token = SecureRandom.hex(12)
      person.user.remember_token = token
      person.user.remember_token_expires_at = 1.month.from_now
      person.user.save(validate: false)
      LeaderMailer.added(person, added_by, self, token).deliver
    end

    private

    def notify_user
      if admins
        OrganizationMailer.enqueue.notify_user(id)
      end
      true
    end

    def notify_user_of_denial
      if admins
        OrganizationMailer.enqueue.notify_user_of_denial(id)
      end
      true
    end

end
