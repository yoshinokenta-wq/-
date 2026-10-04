# frozen_string_literal: true

# 単語帳モードと並び替えモードで扱う静的データ
module InterviewData
  VOCABULARY = [
    {
      word: '志望動機',
      reading: 'しぼうどうき',
      meaning: 'なぜその学校を志望したのか、その理由。',
      example: '志望動機を教えてください。'
    },
    {
      word: '自己PR',
      reading: 'じこピーアール',
      meaning: '自分の強みや特色を相手に伝えること。',
      example: 'あなたの自己PRをお願いします。'
    },
    {
      word: 'マナー',
      reading: 'マナー',
      meaning: '社会で守るべき礼儀や行動の決まり。',
      example: '面接でのマナーを守ります。'
    },
    {
      word: '寛容',
      reading: 'かんよう',
      meaning: '他人の違いを広く受け入れる心。',
      example: '寛容な気持ちを大切にしています。'
    },
    {
      word: '責務',
      reading: 'せきむ',
      meaning: '自分の役割に対して責任を持つこと。',
      example: '部活動での責務を果たします。'
    },
    {
      word: '研鑽',
      reading: 'けんさん',
      meaning: 'ひたすら努力すること。',
      example: '研鑽によって実力をつける。'
    }
  ].freeze

  ORDERING_SETS = [
    {
      title: "正しい入室・着席の流れ",
      answer: ["nokku", "ozigi", "seki", "suwaru"],
      items: [
        { id: "nokku", image: "/images/nokku.png" },
        { id: "ozigi", image: "/images/ozigi.png" },
        { id: "seki", image: "/images/seki.png" },
        { id: "suwaru", image: "/images/suwaru.png" }
      ]
    }
  ].freeze

  module_function

  def vocabulary
    VOCABULARY
  end

  def ordering_sets
    ORDERING_SETS
  end
end
