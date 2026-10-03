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
      title: '面接の入退室の正しい流れ',
      answer: %w[2 4 1 3],
      items: [
        { id: '1', label: 'ノックして「失礼します」と言い入室する' },
        { id: '2', label: '「どうぞ」という声を待ってから入る' },
        { id: '3', label: '退室時も「失礼しました」と挨拶して出る' },
        { id: '4', label: '指定された席に座り、開始を待つ' }
      ]
    },
    {
      title: '質問されたときの正しい姿勢',
      answer: %w[1 3 2 4],
      items: [
        { id: '1', label: '「はい」と返事をして、姿勢を正す' },
        { id: '2', label: '相手の目を見て、聞こえた内容を確認してから答える' },
        { id: '3', label: '内容を整理してから話し始める' },
        { id: '4', label: '回答が終わったら、「ありがとうございました」と述べる' }
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
