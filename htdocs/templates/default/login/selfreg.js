var regbox;

function submit_regform() {
    regbox.close();
    $('answer').set('value', $('secquest').get('value'));
    $('regform').submit();
}