<requireAuth/>
<apply template='default'>

<h2>Create a new repository</h2>

<form method='post' action='/repositories'>
  <dl>
    <dt><label for='name'>Repository Name</label></dt>
    <dd><input id='name' name='name' type='text' class='autofocus'></dd>
  </dl>

  <dl>
    <dt><label for='description'>Description</label></dt>
    <dd><input id='description' name='description' type='text'></dd>
  </dl>

  <button type='submit'>Create repository</button>
</form>

</apply>
