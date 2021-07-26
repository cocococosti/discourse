# frozen_string_literal: true

require 'rails_helper'

describe BackupRestore::Backuper do
  it 'returns a non-empty parameterized title when site title contains unicode' do
    SiteSetting.title = 'Ɣ'
    backuper = BackupRestore::Backuper.new(Discourse.system_user.id)

    expect(backuper.send(:get_parameterized_title)).to eq("discourse")
  end

  it 'returns a valid parameterized site title' do
    SiteSetting.title = "Coding Horror"
    backuper = BackupRestore::Backuper.new(Discourse.system_user.id)

    expect(backuper.send(:get_parameterized_title)).to eq("coding-horror")
  end

  describe '#notify_user' do
    it 'include upload' do
      backuper = BackupRestore::Backuper.new(Discourse.system_user.id)
      expect { backuper.send(:notify_user) }
        .to change { Topic.private_messages.count }.by(1)
        .and change { Upload.count }.by(1)
    end
  end
end
