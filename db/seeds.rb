# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Daley', city: cities.first)

def create_person
  p = Person.create!(first_name: Faker::Name.first_name, last_name: Faker::Name.last_name)
  p.phone_numbers.create!(number: Faker::PhoneNumber.phone_number, location: 'mobile')
  email = Faker::Internet.email
  p.email_addresses.create!(email: email)
  p.user = User.create!(username: email, email: email, password: 'foobar')
  p.save!
  p
end

Person.transaction do
  if Label.all.empty?
    Label.create(name: 'Admin', i18n: 'admin', organization_id: 0)
    Label.create(name: 'Contact', i18n: 'contact',  organization_id: 0)
    Label.create(name: 'Involved', i18n: 'involved',  organization_id: 0)
    Label.create(name: 'Leader', i18n: 'leader',  organization_id: 0)
    Label.create(name: 'Alumni', i18n: 'alumni',  organization_id: 0)

    # Surveys
    predefined = Survey.create!(title: 'Predefined Questions', post_survey_message: 'Thanks!')
    predefined.elements << TextField.create(label: 'First Name')
    predefined.elements << TextField.create(label: 'Last Name')
    predefined.elements << TextField.create(label: 'Email Address')
  end

  unless Rails.env.test?
    # Orgs
    top = Organization.create!(name: 'Top Level', terminology: 'Organization')
    sub1 = Organization.create!(name: 'Second Level', terminology: 'Ministry', parent: top)
    sub2 = Organization.create!(name: 'Third Level', terminology: 'Campus', parent: sub1)

    # Contacts
    1000.times do |_i|
      p = create_person
      sub2.add_contact(p)
    end

    # leaders
    10.times do |_i|
      p = create_person
      sub2.add_leader(p)
    end
  end
end