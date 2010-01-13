# = About
# 
# Simple cloneable interface for ActiveRecord that allows you to call #clone! on a record and have it
# replicate itself to another object and save itsef. supports basic association cloneing by calling
# clone! on each association you specify using +options[:with]+
# 
# This was created for a specific reason (archiving some records when the tables are flushed with current data), and hasn't really been 
# tested or built out to support a wide range of uses. This is in an early BETA state and hasn't been fully tested. 
# Validation and association failures will _not_ roll back the clone!, this can be a huge limitation currently. (Hopefully I can get this fixed in an upcoming release)
# 
# Author:: Rob Hurring (rob at zerobased dot com)
# Date:: 01/12/2010
# Homepage:: http://blog.ubrio.us
# Copyright:: 2010 Zerobased, LLC
# License:: DWTFYWWI
# 
# === TODO
# 
# * add transactions and rollback when associations/objects fail to save?
# * handle validation failures?
# 
# === Example
#   
#   # Your master records
#   class Company
#     has_many :employees, :dependent => :destroy
#     # Our Archive::Company has a +company_name+ attribute, while we are using a +name+ attribute. We also don't want to include
#     # our +bank_details+ in the archive.
#     cloneable :to => ::Archive::Company, :map => {:name => :company_name}, :exclude => [:bank_details], :with => :employees
#     
#     # After we remove a company, archive it along with all the employees
#     after_destroy :clone!
#   end
# 
#   class Employee
#     belongs_to :company
#     cloneable :to => ::Archive::Employee, :include => [:calculated_worth], :map => {:full_name => :name}
# 
#     # some dynamic method that we want to store. our Archive::Employee model will have a +calculated_worth+ attribute
#     def calculated_worth
#       1_000_000
#     end
# 
#     # we have first_name & last_name attributes, our Archive::Employee model only has a +name+ attribute.
#     def full_name
#       "#{first_name} #{last_name}"
#     end
#   end
# 
#   # Some models based out of another database (or table)
#   module Archive
#     class Company
#       has_many :employees
#     end
# 
#     class Employee
#       belongs_to :company
#     end
#   end
module Cloneable
  # The main hook that is called within your ActiveRecord model.
  # 
  # *Options*
  # 
  # [:to]  This is the object to clone ourself to. If left out, we will clone to a new instance of <tt>self</tt>. (This isn't a great thing to do since any uniqueness validations will kill the clone)
  # [:map] A map of attributes from the master => slave. If we are cloning a user and the master has a first_name and last_name attribute, but the slave has a <tt>name</tt> attribute, we could create a simple method that will combine names and send it to the <tt>name=</tt> method on the slave object. If no <tt>:map</tt> key is specified, we will attempt to clone all the master's <tt>attribute.keys</tt>
  #   
  #   # :map => {:full_name => :name}
  #   def full_name
  #     first_name + ' ' + last_name
  #   end
  # 
  # [:include] A list of other attributes to map to the slave object. These will be on a 1-to-1 relationship, if the naming is different, use the <tt>:map</tt> option
  # [:exclude] A list of attributes to exclude when cloning
  # [:with] An array of associations you wish to map. This should handle <tt>has_many</tt> and <tt>has_one</tt>. Support for polymorphic and has_many_through is not tested.
  # [:unless] A proc/instance method that blocks the clone. This should return <tt>FALSE</tt> for the clone to continue.
  # 
  # *Example*
  # 
  # when cloneing the user, include all their projects
  #   class User < AR::Base
  #     has_many :projects
  #     cloneable :with => :projects
  #   end
  # 
  # cloneable must also be described for the project model. This can also have a <tt>:with</tt> option, if project has any HM associations.
  #   class Project < AR::Base
  #     belongs_to :user
  #     cloneable
  #   end
  # 
  def cloneable(options = {})
    cattr_accessor :cloneable_options
    self.cloneable_options = options
    include InstanceMethods
  end
  
  module InstanceMethods
    # If the <tt>:unless</tt> options has been passed in, call that method/proc and see how it returns
    def block_clone?
      return self.class.cloneable_options[:unless].to_proc.call(self) if self.class.cloneable_options[:unless]
    end
    
    # Build the list of attributes we are to clone. If no <tt>:map</tt> options is passed in, we default to the master object's attribute keys. We also add in any <tt>:include</tt> and remove and <tt>:exclude</tt> options.
    def cloneable_attributes
      ((self.class.cloneable_options[:map] || attributes).keys.map(&:to_sym) \
        + (self.class.cloneable_options[:include] || []) \
        - (self.class.cloneable_options[:exclude] || [])).uniq
    end
    
    # Builds a slave object. If no <tt>:to</tt> option is specified, we will create a new instance of ourself and pass that along.
    def cloneable_receiver
      @cloneable_receiver ||= begin
        self.class.cloneable_options[:to].new
      rescue
        self.class.new
      end
    end
    
    # If a <tt>:with</tt> option is specified we loop through all associated reocords and call the <tt>#clone!</tt> method on that object. All associated objects should also make sure to
    # either define a <tt>clone!</tt> method, or setup a <tt>cloneable</tt> act.
    #--
    # TODO: won't support polymorphic/HMT associations - should use "parent=" instead of "parent_id=" (primary_key_name) 
    # TODO: test with a has_one association   
    def clone_associations!
      with = Array(self.class.cloneable_options[:with])
      return if with.empty?
      
      with.each do |association|
        association_macro = self.class.reflect_on_association(association)
        primary_key = association_macro.primary_key_name.to_sym
        receiver_pk = cloneable_receiver.id
        
        Array(send(association)).each do |object|
          object.clone!({primary_key => receiver_pk})
        end
      end
    end
    
    # Clone the object, and all associated objects. Args is used by parent clones to pass along their relative information to the children clones. If we are cloneing a User that has many Projects, User's clone! method will call each of its project's clone! method and pass in <tt>{:user_id => self.id}</tt> so the project knows how to link up
    #--
    # TODO: clean this up, link associations better.
    def clone!(*args)
      options = self.class.cloneable_options
      associations = args.extract_options!
      return if block_clone?
      
      # Clone the basic object
      cloneable_attributes.each do |attribute|
        destination_method = options[:map].try(:[], attribute) || attribute
        cloneable_receiver.send(:"#{destination_method}=", send(attribute))        
      end

      # Set association links. Association foreign_keys should be passed in through *args
      # If we're cloneing a User with many Projects and we're in the project#clone! method, it will have a :user_id => (ID) association hash passed in, we just set that.
      associations.each do |(key, value)|
        cloneable_receiver.send(:"#{key}=", value)
      end
      
      # Save ourself
      cloneable_receiver.save!
      
      # Hadle all our associations
      clone_associations!      
    end
  end
end
 
ActiveRecord::Base.extend Cloneable