class Quran::Lemma < ActiveRecord::Base
    extend Quran

    self.table_name = 'lemma'
    self.primary_key = 'lemma_id'

    has_many :_word_lemma, class_name: 'Quran::WordLemma', foreign_key: 'lemma_id'

    has_many :words, class_name: 'Quran::Word', through: :_word_lemma
    has_many :tokens, class_name: 'Quran::Token', through: :words
    has_many :stems, class_name: 'Quran::Stem', through: :words
    has_many :roots, class_name: 'Quran::Root', through: :words
    has_many :ayahs, class_name: 'Quran::Ayah', through: :words
end

